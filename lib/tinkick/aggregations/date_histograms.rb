# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  class Aggregations
    module DateHistograms
      extend ActiveSupport::Concern

      private

      def date_histogram(field, options, conditions)
        # @type self: Aggregations
        unknown = options.keys - [:field, :calendar_interval, :fixed_interval, :min_doc_count, :order, :keyed, :time_zone, :format, :offset, :extended_bounds, :hard_bounds, :missing]
        raise ArgumentError, "Unknown date histogram options: #{unknown.join(", ")}" unless unknown.empty?
        unless [:calendar_interval, :fixed_interval].count { |kind| options.key?(kind) } == 1
          raise ArgumentError, "Date histogram requires exactly one calendar_interval or fixed_interval"
        end
        bucket_offset = date_histogram_offset(options.fetch(:offset, 0))

        unit = nil
        if options.key?(:fixed_interval)
          interval_milliseconds = fixed_interval_milliseconds(options.fetch(:fixed_interval))
          step = "#{interval_milliseconds} milliseconds"
        else
          interval = options[:calendar_interval].to_s
          aliases = { "1s" => "second", "1m" => "minute", "1h" => "hour", "1d" => "day", "1w" => "week", "1M" => "month", "1q" => "quarter", "1y" => "year", "months" => "month", "years" => "year" }
          unit = aliases.fetch(interval, interval)
          unless ["second", "minute", "hour", "day", "week", "month", "quarter", "year"].include?(unit)
            raise ArgumentError, "calendar_interval must be one second, minute, hour, day, week, month, quarter, or year"
          end
          step = unit == "quarter" ? "3 months" : "1 #{unit}"
        end
        minimum = options.fetch(:min_doc_count, 0)
        raise ArgumentError, "Date histogram min_doc_count must be a nonnegative integer" unless minimum.is_a?(Integer) && minimum >= 0
        raise ArgumentError, "Date histogram keyed must be true or false" unless [true, false].include?(options.fetch(:keyed, false))
        if options.key?(:format) && !options[:format].is_a?(String)
          raise ArgumentError, "date_histogram format must be a string"
        end
        formatter = AggregationDate.new(time_zone: options[:time_zone], format: options[:format])
        zoned_date_histogram(field, options, conditions, formatter, unit, step, bucket_offset, minimum)
      end

      def zoned_date_histogram(field, options, conditions, formatter, unit, step, bucket_offset, minimum)
        # @type self: Aggregations
        adjustment = "#{bucket_offset} milliseconds"
        zone = histogram_zone(formatter, options[:time_zone])
        binds = { zone: zone, step: step, adjustment: adjustment, series_zone: unit ? zone : "UTC" }
        binds[:unit] = unit if unit
        lower_date, upper_date, hard_lower, hard_upper = zoned_histogram_bounds(options, formatter, binds, unit: unit)
        scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
        values = values_relation(scope, field, missing: date_missing(field, options[:missing], formatter))
        column = @model.columns_hash.fetch(field)
        unless [:date, :datetime, :timestamp].include?(column.type)
          raise InvalidQueryError, "date_histogram requires a date or datetime aggregation column"
        end
        value = column.sql_type.include?("with time zone") ? "_tinkick_value" : "_tinkick_value::timestamp AT TIME ZONE 'UTC'"
        rounding = zoned_rounding_sql("(#{value}) - CAST(:adjustment AS interval)", unit: unit)
        dates = @unscoped.from(values, :tinkick_values)
          .where(Arel.sql("_tinkick_value IS NOT NULL"))
          .select(Arel.sql("#{rounding} AS _tinkick_date, _tinkick_document_id", **binds))
        counts = @unscoped.from(dates, :tinkick_dates)
          .group(Arel.sql("_tinkick_date"))
          .select(Arel.sql("_tinkick_date, COUNT(DISTINCT _tinkick_document_id) AS _tinkick_count"))
        counts = counts.where(Arel.sql("_tinkick_date >= ?::timestamptz - ?::interval", hard_lower, adjustment)) if hard_lower
        counts = counts.where(Arel.sql("_tinkick_date < ?::timestamptz - ?::interval", hard_upper, adjustment)) if hard_upper
        query = date_histogram_query(counts, minimum, lower_date, upper_date, step, binds.fetch(:series_zone))
        shifted = "_tinkick_date + CAST(:adjustment AS interval)"
        query = query.select(Arel.sql(<<~SQL, **binds)).order(Arel.sql(order_sql(options.fetch(:order, { _key: :asc }))))
          (EXTRACT(EPOCH FROM (#{shifted})) * 1000)::bigint AS _tinkick_key,
          COALESCE(_tinkick_count, 0) AS _tinkick_count,
          EXTRACT(EPOCH FROM (((#{shifted}) AT TIME ZONE :zone) - ((#{shifted}) AT TIME ZONE 'UTC')))::integer AS _tinkick_offset
        SQL
        # @type var rows: Array[aggregation_date_histogram_row]
        rows = @model.with_connection { |connection| connection.select_all(query).to_a }
        # @type var buckets: Array[aggregation_date_histogram_bucket]
        buckets = rows.map do |row|
          key = row.fetch("_tinkick_key")
          { "key" => key, "key_as_string" => formatter.format(key.to_f, utc_offset: row.fetch("_tinkick_offset")), "doc_count" => row.fetch("_tinkick_count") }
        end
        # @type var result: aggregation_date_histogram
        result = { "buckets" => options[:keyed] ? keyed_date_buckets(buckets) : buckets }
        result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
        result
      end

      def keyed_date_buckets(buckets)
        # @type var keyed: Hash[String, aggregation_date_histogram_bucket]
        keyed = {}
        buckets.each { |bucket| keyed[bucket.fetch("key_as_string")] = bucket }
        keyed
      end

      def histogram_zone(formatter, time_zone)
        # @type self: Aggregations
        offset = formatter.fixed_offset
        if offset.nil?
          time_zone.to_s
        elsif offset.zero?
          "UTC"
        else
          hours, rest = offset.abs.divmod(3_600)
          minutes, seconds = rest.divmod(60)
          # PostgreSQL timezone strings use POSIX signs, opposite ISO8601 offsets.
          format("UTC%s%02d:%02d:%02d", offset.positive? ? "-" : "+", hours, minutes, seconds)
        end
      end

      def date_histogram_query(counts, minimum, lower_date, upper_date, step, series_zone)
        # @type self: Aggregations
        if minimum.zero?
          Tinkick.warn(@model, "Tinkick: date_histogram min_doc_count: 0 generates empty buckets across the date range. Small intervals over wide ranges can produce many buckets; use min_doc_count: 1 when empty buckets are unnecessary.")
          bounds = @unscoped.from("tinkick_date_counts")
            .select(Arel.sql("LEAST(MIN(_tinkick_date), ?::timestamptz) AS lower, GREATEST(MAX(_tinkick_date), ?::timestamptz) AS upper", lower_date, upper_date))
          grid_join = @model.sanitize_sql_array([<<~SQL, step, series_zone])
            CROSS JOIN LATERAL (
              SELECT value AS _tinkick_date
              FROM generate_series(lower, upper, CAST(? AS interval), ?) AS series(value)
              UNION SELECT _tinkick_date FROM tinkick_date_counts
            ) AS tinkick_date_grid
          SQL
          # Native calendar series and truncation can land on different boundaries
          # across timezone changes. Retain every observed bucket alongside the series.
          @unscoped.with(tinkick_date_counts: counts).from(bounds, :tinkick_bounds)
            .joins(grid_join)
            .joins("LEFT JOIN tinkick_date_counts USING (_tinkick_date)")
        else
          @unscoped.from(counts, :tinkick_date_counts).where(Arel.sql("_tinkick_count >= ?", minimum))
        end
      end

      def zoned_rounding_sql(value, unit:)
        # @type self: Aggregations
        if unit
          "date_trunc(:unit, #{value}, :zone)"
        else
          "date_bin(CAST(:step AS interval), #{value}, TIMESTAMP '1970-01-01' AT TIME ZONE :zone)"
        end
      end

      def zoned_histogram_bounds(options, formatter, binds, unit:)
        # @type self: Aggregations
        # @type var default_bounds: aggregation_date_histogram_bounds
        default_bounds = {}
        bounds_options = [options.fetch(:extended_bounds, default_bounds), options.fetch(:hard_bounds, default_bounds)]
        values = bounds_options.flat_map do |bounds|
          unless bounds.is_a?(Hash) && (bounds.keys - [:min, :max]).empty?
            raise ArgumentError, "Date histogram bounds must be a hash containing only min and max"
          end
          lower = formatter.histogram_bound(bounds[:min])
          upper = formatter.histogram_bound(bounds[:max])
          raise ArgumentError, "Date histogram bounds min cannot exceed max" if lower && upper && lower > upper

          [lower, upper]
        end
        return [nil, nil, nil, nil] if values.all?(&:nil?)

        inputs = values.each_with_index.to_h { |value, index| ["bound#{index}".to_sym, value && Time.at(Rational(value, 1_000)).utc] }
        expressions = values.each_index.map { |index| "(EXTRACT(EPOCH FROM #{zoned_rounding_sql("CAST(:bound#{index} AS timestamptz)", unit: unit)}) * 1000)::bigint AS bound#{index}" }
        query = @unscoped.from("pg_catalog.pg_extension").where("extname = 'tin'")
          .select(Arel.sql(expressions.join(", "), **binds, **inputs))
        # @type var row: Hash[String, Integer?]
        row = @model.with_connection { |connection| connection.select_one(query) } || {}
        lower, upper, hard_lower, hard_upper = (0..3).map do |index|
          value = row["bound#{index}"]
          value && Time.at(Rational(value, 1_000)).utc
        end
        if (lower && hard_lower && lower < hard_lower) || (upper && hard_upper && upper > hard_upper)
          raise ArgumentError, "Extended bounds must be within hard bounds"
        end

        [lower, upper, hard_lower, hard_upper]
      end

      def date_histogram_offset(value)
        # @type self: Aggregations
        milliseconds = case value
        when Integer, Float
          raise ArgumentError, "numeric milliseconds must be finite" if value.is_a?(Float) && !value.finite?

          value.to_i
        when String
          direction = value.start_with?("-") ? -1 : 1
          text = value.delete_prefix("-").delete_prefix("+")
          /\A0+\z/.match?(text.strip) ? 0 : fixed_interval_milliseconds(text, allow_zero: true) * direction
        else
          raise ArgumentError, "must be numeric milliseconds or a signed time value"
        end
        unless milliseconds.between?(-(2**63), 2**63 - 1)
          raise ArgumentError, "milliseconds must fit in a signed 64-bit integer"
        end

        milliseconds
      rescue ArgumentError => error
        raise ArgumentError, "Invalid date_histogram offset: #{error.message}"
      end

      def fixed_interval_milliseconds(value, allow_zero: false)
        # @type self: Aggregations
        text = value.to_s
        match = /\A(\+?[0-9]+)\s*(nanos|micros|ms|s|m|h|d)\z/.match(text.strip.downcase)
        unless match && (match[2] != "m" || text.end_with?("m"))
          raise ArgumentError, "fixed_interval must use an integer quantity and ms, s, m, h, d, micros, or nanos"
        end

        quantity = match[1].to_s.to_i
        unless quantity >= 0 && quantity <= (2**63 - 1)
          raise ArgumentError, "fixed_interval quantity must be a nonnegative 64-bit integer"
        end
        unit = match[2].to_s
        milliseconds = case unit
        when "nanos" then quantity / 1_000_000
        when "micros" then quantity / 1_000
        else quantity * { "ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000 }.fetch(unit)
        end
        raise ArgumentError, "fixed_interval must be at least one millisecond" unless allow_zero || milliseconds.positive?

        milliseconds
      end
    end
  end
end
