# frozen_string_literal: true

require_relative "filter"
require_relative "aggregation_date"

module Tinkick
  class Aggregations
    def initialize(model, scope, dictionary_scope: model.all)
      @model = model
      @scope = scope.except(:select, :order, :limit, :offset)
      @dictionary_scope = dictionary_scope.except(:select, :order, :limit, :offset)
      @now = Time.now
    end

    def call(spec)
      aggregations = if spec.is_a?(Array)
        spec.to_h do |field|
          # @type var options: aggregation_options
          options = {}
          [field, options]
        end
      else
        spec
      end
      raise ArgumentError, "Aggregations must be an array of fields or an options hash" unless aggregations.is_a?(Hash)

      aggregations.to_h do |name, options|
        raise ArgumentError, "Aggregation options must be a hash" unless options.is_a?(Hash)

        # @type var metric_names: Array[aggregation_metric_name]
        metric_names = [:avg, :cardinality, :max, :min, :sum]
        unknown = options.keys - [:field, :limit, :order, :min_doc_count, :where, :ranges, :date_ranges, :histogram, :date_histogram, :keyed, :time_zone, :format, *metric_names]
        raise ArgumentError, "Unknown aggregation options: #{unknown.join(", ")}" unless unknown.empty?

        metrics = metric_names.select { |metric| options.key?(metric) }
        raise ArgumentError, "Each aggregation must select only one metric" if metrics.length > 1
        range_kinds = [:ranges, :date_ranges].select { |kind| options.key?(kind) }
        histogram_kinds = [:histogram, :date_histogram].select { |kind| options.key?(kind) }
        if range_kinds.length + metrics.length + histogram_kinds.length > 1
          raise ArgumentError, "Each aggregation must select only one range kind, histogram, or metric"
        end
        raise ArgumentError, "keyed applies only to range aggregations" if options.key?(:keyed) && range_kinds.empty?
        raise ArgumentError, "time_zone applies only to date aggregations" if options.key?(:time_zone) && !options.key?(:date_ranges)
        if options.key?(:format) && !options.key?(:date_ranges) && !options.key?(:date_histogram)
          raise ArgumentError, "format applies only to date aggregations"
        end

        result = if options.key?(:date_histogram)
          outer = options.keys - [:date_histogram, :where]
          unless outer.empty?
            raise ArgumentError, "Date histogram settings must be inside date_histogram:; only where: may accompany it"
          end
          settings = options.fetch(:date_histogram)
          raise ArgumentError, "date_histogram must be an options hash" unless settings.is_a?(Hash)

          date_histogram((settings[:field] || name).to_s, settings, options[:where])
        elsif options.key?(:histogram)
          outer = options.keys - [:histogram, :where]
          unless outer.empty?
            raise ArgumentError, "Histogram settings must be inside histogram:; only where: may accompany it (unsupported outer options: #{outer.join(", ")})"
          end
          settings = options.fetch(:histogram)
          raise ArgumentError, "histogram must be an options hash" unless settings.is_a?(Hash)

          numeric_histogram((settings[:field] || name).to_s, settings, options[:where])
        elsif options.key?(:date_ranges)
          range_aggregation((options[:field] || name).to_s, options.fetch(:date_ranges), options, dates: true)
        elsif options.key?(:ranges)
          range_aggregation((options[:field] || name).to_s, options.fetch(:ranges), options)
        elsif metrics.empty?
          terms((options[:field] || name).to_s, options)
        else
          metric = metrics.fetch(0)
          metric_options = options.fetch(metric)
          unless metric_options.is_a?(Hash) && (metric_options.keys - [:field]).empty?
            raise ArgumentError, "Metric options must be a hash containing a field"
          end
          calculate_metric(metric, (metric_options[:field] || name).to_s, options[:where])
        end
        [name.to_s, result]
      end
    end

    private

    def date_histogram(field, options, conditions)
      unknown = options.keys - [:field, :calendar_interval, :fixed_interval, :min_doc_count, :order, :keyed, :time_zone, :format, :offset, :extended_bounds, :hard_bounds]
      raise ArgumentError, "Unknown date histogram options: #{unknown.join(", ")}" unless unknown.empty?
      unless [:calendar_interval, :fixed_interval].count { |kind| options.key?(kind) } == 1
        raise ArgumentError, "Date histogram requires exactly one calendar_interval or fixed_interval"
      end
      bucket_offset = date_histogram_offset(options.fetch(:offset, 0))
      adjustment = "#{bucket_offset} milliseconds"

      unit = nil
      interval_milliseconds = 1
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
      formatter = AggregationDate.new(time_zone: options[:time_zone], format: options[:format], now: @now)
      offset = formatter.fixed_offset
      if offset.nil? && !["day", "week", "month", "quarter", "year"].include?(unit)
        raise ArgumentError, "IANA time_zone currently requires a day, week, month, quarter, or year calendar_interval"
      end
      # Bounds round without the aggregation offset, which is added to final keys.
      lower_date, upper_date = date_histogram_bounds(options.fetch(:extended_bounds, {}), formatter, unit: unit, interval: interval_milliseconds)
      hard_lower, hard_upper = date_histogram_bounds(options.fetch(:hard_bounds, {}), formatter, unit: unit, interval: interval_milliseconds)
      if (lower_date && hard_lower && formatter.histogram_key(lower_date) < formatter.histogram_key(hard_lower)) ||
          (upper_date && hard_upper && formatter.histogram_key(upper_date) > formatter.histogram_key(hard_upper))
        raise ArgumentError, "Extended bounds must be within hard bounds"
      end

      shift = "#{offset || 0} seconds"

      scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
      values = values_relation(scope, field)
      column = @model.columns_hash.fetch(field)
      unless [:date, :datetime, :timestamp].include?(column.type)
        raise InvalidQueryError, "date_histogram requires a date or datetime aggregation column"
      end
      value = column.sql_type.include?("with time zone") ? "_tinkick_value AT TIME ZONE 'UTC'" : "_tinkick_value::timestamp"
      rounding = if offset.nil?
        Arel.sql("date_trunc(?, ((#{value}) - ?::interval) AT TIME ZONE 'UTC' AT TIME ZONE ?) AS _tinkick_date, _tinkick_document_id", unit, adjustment, options[:time_zone].to_s)
      elsif unit
        Arel.sql("date_trunc(?, (#{value}) - ?::interval + ?::interval) AS _tinkick_date, _tinkick_document_id", unit, adjustment, shift)
      else
        Arel.sql("date_bin(?::interval, (#{value}) - ?::interval + ?::interval, TIMESTAMP '1970-01-01') AS _tinkick_date, _tinkick_document_id", step, adjustment, shift)
      end
      dates = @model.unscoped.from(values, :tinkick_values)
        .where(Arel.sql("_tinkick_value IS NOT NULL"))
        .select(rounding)
      counts = @model.unscoped.from(dates, :tinkick_dates)
        .group(Arel.sql("_tinkick_date"))
        .select(Arel.sql("_tinkick_date, COUNT(DISTINCT _tinkick_document_id) AS _tinkick_count"))
      if hard_lower
        cutoff = formatter.histogram_cutoff(hard_lower, offset: bucket_offset, unit: unit, interval: interval_milliseconds)
        counts = counts.where(Arel.sql("_tinkick_date >= ?::timestamp", cutoff))
      end
      if hard_upper
        cutoff = formatter.histogram_cutoff(hard_upper, offset: bucket_offset, unit: unit, interval: interval_milliseconds)
        counts = counts.where(Arel.sql("_tinkick_date < ?::timestamp", cutoff))
      end
      query = if minimum.zero?
        @model.logger&.warn("Tinkick: date_histogram min_doc_count: 0 generates empty buckets across the date range. Small intervals over wide ranges can produce many buckets; use min_doc_count: 1 when empty buckets are unnecessary.")
        bounds = @model.unscoped.from("tinkick_date_counts")
          .select(Arel.sql("LEAST(MIN(_tinkick_date), ?::timestamp) AS lower, GREATEST(MAX(_tinkick_date), ?::timestamp) AS upper, ?::interval AS step", lower_date, upper_date, step))
        @model.unscoped.with(tinkick_date_counts: counts)
          .from(bounds, :tinkick_bounds)
          .joins("CROSS JOIN LATERAL generate_series(lower, upper, step) AS tinkick_series(_tinkick_date)")
          .joins("LEFT JOIN tinkick_date_counts USING (_tinkick_date)")
          .select(Arel.sql("(EXTRACT(EPOCH FROM _tinkick_date - ?::interval) * 1000)::bigint AS _tinkick_key, COALESCE(_tinkick_count, 0) AS _tinkick_count", shift))
      else
        @model.unscoped.from(counts, :tinkick_date_counts)
          .where(Arel.sql("_tinkick_count >= ?", minimum))
          .select(Arel.sql("(EXTRACT(EPOCH FROM _tinkick_date - ?::interval) * 1000)::bigint AS _tinkick_key, _tinkick_count", shift))
      end
      query = query.order(Arel.sql(order_sql(options.fetch(:order, { _key: :asc }))))
      # @type var rows: Array[{ "_tinkick_key" => Integer, "_tinkick_count" => Integer }]
      rows = @model.with_connection { |connection| connection.select_all(query).to_a }
      buckets = rows.map do |row|
        key = row.fetch("_tinkick_key")
        key = formatter.midnight_key(key) if offset.nil?
        key += bucket_offset
        { "key" => key, "key_as_string" => formatter.format(key.to_f), "doc_count" => row.fetch("_tinkick_count") }
      end
      if offset.nil?
        # A skipped local date can generate an empty bucket with the next day's
        # UTC key. Keep the populated bucket and preserve the SQL count ordering.
        populated = buckets.reject { |bucket| bucket.fetch("doc_count").zero? }.to_h { |bucket| [bucket.fetch("key"), true] }
        buckets = buckets.reject { |bucket| bucket.fetch("doc_count").zero? && populated.key?(bucket.fetch("key")) }
          .uniq { |bucket| bucket.fetch("key") }
      end
      # @type var result: aggregation_date_histogram
      result = { "buckets" => options[:keyed] ? buckets.to_h { |bucket| [bucket.fetch("key_as_string"), bucket] } : buckets }
      result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
      result
    end

    def date_histogram_bounds(bounds, formatter, unit:, interval:)
      unless bounds.is_a?(Hash) && (bounds.keys - [:min, :max]).empty?
        raise ArgumentError, "Date histogram bounds must be a hash containing only min and max"
      end
      lower = formatter.histogram_bound(bounds[:min])
      upper = formatter.histogram_bound(bounds[:max])
      raise ArgumentError, "Date histogram bounds min cannot exceed max" if lower && upper && lower > upper

      [lower && formatter.histogram_boundary(lower, unit: unit, interval: interval),
       upper && formatter.histogram_boundary(upper, unit: unit, interval: interval)]
    end

    def date_histogram_offset(value)
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

    def numeric_histogram(field, options, conditions)
      unknown = options.keys - [:field, :interval, :offset, :min_doc_count, :order, :keyed, :extended_bounds, :hard_bounds]
      raise ArgumentError, "Unknown histogram options: #{unknown.join(", ")}" unless unknown.empty?

      interval = numeric_bound(options[:interval])
      offset = numeric_bound(options.fetch(:offset, 0))
      raise ArgumentError, "Histogram interval must be positive and offset must be numeric" unless interval && interval.positive? && offset

      minimum = options.fetch(:min_doc_count, 0)
      raise ArgumentError, "Histogram min_doc_count must be a nonnegative integer" unless minimum.is_a?(Integer) && minimum >= 0
      raise ArgumentError, "Histogram keyed must be true or false" unless [true, false].include?(options.fetch(:keyed, false))
      extended_min, extended_max = histogram_bounds(options.fetch(:extended_bounds, {}))
      hard_min, hard_max = histogram_bounds(options.fetch(:hard_bounds, {}))
      if (extended_min && hard_min && extended_min < hard_min) || (extended_max && hard_max && extended_max > hard_max)
        raise ArgumentError, "Extended bounds must be within hard bounds"
      end

      scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
      values = values_relation(scope, field)
      unless [:integer, :decimal, :float].include?(@model.columns_hash.fetch(field).type)
        raise InvalidQueryError, "histogram requires a numeric aggregation column"
      end
      ordinals = @model.unscoped.from(values, :tinkick_values)
        .where(Arel.sql("_tinkick_value IS NOT NULL"))
        .select(Arel.sql("FLOOR((_tinkick_value::double precision - ?) / ?) AS _tinkick_ordinal, _tinkick_document_id", offset, interval))
      counts = @model.unscoped.from(ordinals, :tinkick_ordinals)
        .group(Arel.sql("_tinkick_ordinal"))
        .select(Arel.sql("_tinkick_ordinal, COUNT(DISTINCT _tinkick_document_id) AS _tinkick_count"))
      # Elasticsearch checks numeric hard bounds before adding the histogram offset.
      counts = counts.where(Arel.sql("_tinkick_ordinal * ? >= ?", interval, hard_min)) if hard_min
      counts = counts.where(Arel.sql("_tinkick_ordinal * ? <= ?", interval, hard_max)) if hard_max
      query = if minimum.zero?
        @model.logger&.warn("Tinkick: histogram min_doc_count: 0 generates empty buckets across the matching numeric range. Small intervals over wide ranges can produce many buckets; use min_doc_count: 1 when empty buckets are unnecessary.")
        lower = extended_min && ((extended_min - offset) / interval).floor
        upper = extended_max && ((extended_max - offset) / interval).floor
        bounds = @model.unscoped.from("tinkick_histogram_counts")
          .select(Arel.sql("LEAST(MIN(_tinkick_ordinal), ?)::numeric AS lower, GREATEST(MAX(_tinkick_ordinal), ?)::numeric AS upper", lower, upper))
        @model.unscoped.with(tinkick_histogram_counts: counts)
          .from(bounds, :tinkick_bounds)
          .joins("CROSS JOIN LATERAL generate_series(lower, upper, 1) AS tinkick_series(_tinkick_ordinal)")
          .joins("LEFT JOIN tinkick_histogram_counts USING (_tinkick_ordinal)")
          .select(Arel.sql("_tinkick_ordinal::double precision * ? + ? AS _tinkick_key, COALESCE(_tinkick_count, 0) AS _tinkick_count", interval, offset))
      else
        @model.unscoped.from(counts, :tinkick_histogram_counts)
          .where(Arel.sql("_tinkick_count >= ?", minimum))
          .select(Arel.sql("_tinkick_ordinal * ? + ? AS _tinkick_key, _tinkick_count", interval, offset))
      end
      query = query.order(Arel.sql(order_sql(options.fetch(:order, { _key: :asc }))))
      # @type var rows: Array[{ "_tinkick_key" => Float, "_tinkick_count" => Integer }]
      rows = @model.with_connection { |connection| connection.select_all(query).to_a }
      buckets = rows.map { |row| { "key" => row.fetch("_tinkick_key"), "doc_count" => row.fetch("_tinkick_count") } }
      # @type var result: aggregation_histogram
      result = { "buckets" => options[:keyed] ? buckets.to_h { |bucket| [bucket.fetch("key").to_s, bucket] } : buckets }
      result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
      result
    end

    def histogram_bounds(bounds)
      unless bounds.is_a?(Hash) && (bounds.keys - [:min, :max]).empty?
        raise ArgumentError, "Histogram bounds must be a hash containing only min and max"
      end

      lower = numeric_bound(bounds[:min])
      upper = numeric_bound(bounds[:max])
      raise ArgumentError, "Histogram bounds max must be greater than or equal to min" if lower && upper && upper < lower

      [lower, upper]
    end

    def terms(field, options)
      limit = options.fetch(:limit, 1_000)
      minimum = options.fetch(:min_doc_count, 1)
      unless limit.is_a?(Integer) && limit.positive? && minimum.is_a?(Integer) && minimum >= 0
        raise ArgumentError, "Aggregation limit must be a positive integer and min_doc_count a nonnegative integer"
      end

      scope = @scope
      conditions = options[:where]
      scope = Filter.new(@model).apply(scope, conditions) if conditions
      values = values_relation(scope, field)
      counts = @model.unscoped.from(values, :tinkick_values)
        .where(Arel.sql("_tinkick_value IS NOT NULL"))
        .group(Arel.sql("_tinkick_value"))
        .select(Arel.sql("_tinkick_value AS _tinkick_key, COUNT(*) AS _tinkick_count"))
      if minimum.zero?
        @model.logger&.warn("Tinkick: min_doc_count: 0 reads the model's scoped term dictionary in addition to matching documents. This can cost more for many distinct values.")
        dictionary = @model.unscoped.from(values_relation(@dictionary_scope, field), :tinkick_values)
          .where(Arel.sql("_tinkick_value IS NOT NULL"))
          .select(Arel.sql("_tinkick_value AS _tinkick_key")).distinct
        counts = @model.unscoped.with(tinkick_dictionary: dictionary, tinkick_matching_counts: counts)
          .from("tinkick_dictionary")
          .joins("LEFT JOIN tinkick_matching_counts USING (_tinkick_key)")
          .select(Arel.sql("_tinkick_key, COALESCE(_tinkick_count, 0) AS _tinkick_count"))
      end
      query = @model.unscoped.from(counts, :tinkick_counts)
        .where(Arel.sql("_tinkick_count >= ?", minimum))
        .select(Arel.sql("_tinkick_key, _tinkick_count, SUM(_tinkick_count) OVER () AS _tinkick_total"))
        .order(Arel.sql(order_sql(options.fetch(:order, { _count: :desc }))))
        .limit(limit)
      # @type var rows: Array[{ "_tinkick_key" => result_value, "_tinkick_count" => Integer, "_tinkick_total" => Numeric }]
      rows = @model.with_connection { |connection| connection.select_all(query).to_a }
      buckets = rows.map { |row| bucket(row.fetch("_tinkick_key"), row.fetch("_tinkick_count").to_i) }
      total = rows.empty? ? 0 : rows.fetch(0).fetch("_tinkick_total").to_i
      # @type var result: aggregation_terms
      result = { "doc_count_error_upper_bound" => 0, "sum_other_doc_count" => total - buckets.sum { |entry| entry.fetch("doc_count") }, "buckets" => buckets }
      result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
      result
    end

    def calculate_metric(metric, field, conditions)
      scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
      values = values_relation(scope, field, unique: false)
      column = @model.columns_hash.fetch(field)
      unless metric == :cardinality || [:integer, :decimal, :float].include?(column.type)
        raise InvalidQueryError, "#{metric} requires a numeric aggregation column"
      end

      if metric == :cardinality
        @model.logger&.warn("Tinkick: cardinality uses exact SQL COUNT(DISTINCT), which can cost more than an approximate estimate for many distinct values.")
        expression = "COUNT(DISTINCT _tinkick_value)"
      else
        expression = "#{metric.to_s.upcase}(_tinkick_value)"
      end
      query = @model.unscoped.from(values, :tinkick_values).select(Arel.sql(expression))
      # @type var value: Integer | Float | BigDecimal | nil
      value = @model.with_connection { |connection| connection.select_value(query) }
      # @type var result: aggregation_metric
      result = { "value" => metric == :cardinality ? (value || 0).to_i : value&.to_f }
      result["value"] = 0.0 if metric == :sum && value.nil?
      result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
      result
    end

    def range_aggregation(field, ranges, options, dates: false)
      raise ArgumentError, "ranges must be a nonempty array" unless ranges.is_a?(Array) && !ranges.empty?
      raise ArgumentError, "keyed must be true or false" unless [true, false].include?(options.fetch(:keyed, false))

      date_values = dates ? AggregationDate.new(format: options[:format], time_zone: options[:time_zone], now: @now) : nil
      buckets = ranges.map do |range|
        unless range.is_a?(Hash) && (range.keys - [:from, :to, :key]).empty?
          raise ArgumentError, "Each range must contain only from, to, or key"
        end
        lower = date_values ? date_values.parse(range[:from]) : numeric_bound(range[:from])
        upper = date_values ? date_values.parse(range[:to]) : numeric_bound(range[:to])
        lower_text = date_values && lower ? date_values.format(lower) : lower&.to_s
        upper_text = date_values && upper ? date_values.format(upper) : upper&.to_s
        key = range[:key]
        raise ArgumentError, "Range key must be a string" unless key.nil? || key.is_a?(String)

        # @type var entry: aggregation_range_bucket
        entry = { "key" => key || "#{lower_text || "*"}-#{upper_text || "*"}", "doc_count" => 0 }
        entry["from"] = lower if lower
        entry["to"] = upper if upper
        entry["from_as_string"] = lower_text if dates && lower_text
        entry["to_as_string"] = upper_text if dates && upper_text
        entry
      end.sort_by { |entry| [entry.fetch("from", -Float::INFINITY), entry.fetch("to", Float::INFINITY)] }
      conditions = options[:where]
      scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
      values = values_relation(scope, field)
      types = dates ? [:date, :datetime, :timestamp] : [:integer, :decimal, :float]
      unless types.include?(@model.columns_hash.fetch(field).type)
        raise InvalidQueryError, "#{dates ? "date_ranges" : "ranges"} requires a #{dates ? "date or datetime" : "numeric"} aggregation column"
      end

      # @type var binds: Array[Float]
      binds = []
      selections = buckets.each_with_index.map do |entry, index|
        predicates = ["_tinkick_value IS NOT NULL"]
        { "from" => ">=", "to" => "<" }.each do |bound, operator|
          value = entry[bound]
          next unless value.is_a?(Float)

          expression = dates ? "(EXTRACT(EPOCH FROM _tinkick_value) * 1000)" : "_tinkick_value::double precision"
          predicates << "#{expression} #{operator} ?"
          binds << value
        end
        "COUNT(DISTINCT _tinkick_document_id) FILTER (WHERE #{predicates.join(" AND ")}) AS _tinkick_range_#{index}"
      end
      query = @model.unscoped.from(values, :tinkick_values).select(Arel.sql(selections.join(", "), *binds))
      # @type var counts: Hash[String, Integer]
      counts = @model.with_connection { |connection| connection.select_one(query) } || {}
      buckets.each_with_index { |entry, index| entry["doc_count"] = counts.fetch("_tinkick_range_#{index}", 0) }
      response_buckets = if options[:keyed]
        buckets.to_h do |entry|
          # @type var keyed_bucket: aggregation_keyed_range_bucket
          keyed_bucket = { "doc_count" => entry.fetch("doc_count") }
          lower = entry["from"]
          upper = entry["to"]
          keyed_bucket["from"] = lower if lower
          keyed_bucket["to"] = upper if upper
          lower_text = entry["from_as_string"]
          upper_text = entry["to_as_string"]
          keyed_bucket["from_as_string"] = lower_text if lower_text
          keyed_bucket["to_as_string"] = upper_text if upper_text
          [entry.fetch("key"), keyed_bucket]
        end
      else
        buckets
      end
      # @type var result: aggregation_ranges
      result = { "buckets" => response_buckets }
      result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
      result
    end

    def numeric_bound(value)
      return if value.nil?

      number = Float(value)
      raise ArgumentError, "Range bounds must be finite numbers" unless number.is_a?(Float) && number.finite?

      number
    rescue TypeError
      raise ArgumentError, "Range bounds must be finite numbers"
    end

    def values_relation(scope, field, unique: true)
      column = @model.columns_hash[field]
      raise MissingFieldError, "#{@model.name} has no aggregation column #{field.inspect}; add it with a Rails migration" unless column
      if [:json, :jsonb].include?(column.type)
        raise InvalidQueryError, "JSON aggregation paths require a scalar field"
      end

      primary_key = @model.primary_key
      raise InvalidQueryError, "Aggregations require a single model primary key" unless primary_key.is_a?(String)

      @model.with_connection do |connection|
        table = connection.quote_table_name(@model.table_name)
        identifier = "#{table}.#{connection.quote_column_name(primary_key)}"
        value = "#{table}.#{connection.quote_column_name(field)}"
        documents = scope.select(Arel.sql("#{identifier} AS _tinkick_document_id, #{value} AS _tinkick_value")).distinct
        if column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
          @model.logger&.warn("Tinkick: array aggregations expand matching array values in PostgreSQL before calculating buckets or metrics. Use selective filters for frequent facets.")
          elements = @model.unscoped.from(documents, :tinkick_documents)
            .joins(Arel.sql("CROSS JOIN LATERAL unnest(tinkick_documents._tinkick_value) AS tinkick_elements(value)"))
            .select(Arel.sql("_tinkick_document_id, tinkick_elements.value AS _tinkick_value"))
          unique ? elements.distinct : elements
        else
          documents
        end
      end
    end

    def order_sql(order)
      orders = order.is_a?(Array) ? order : [order]
      pairs = orders.flat_map do |entry|
        raise ArgumentError, "Aggregation order must use _key or _count" unless entry.is_a?(Hash)

        entry.map do |key, direction|
          column = { "_key" => "_tinkick_key", "_count" => "_tinkick_count" }[key.to_s]
          unless column && ["asc", "desc"].include?(direction.to_s)
            raise ArgumentError, "Aggregation order must use _key or _count with asc or desc"
          end
          "#{column} #{direction.to_s.upcase}"
        end
      end
      pairs << "_tinkick_key ASC" unless pairs.any? { |pair| pair.start_with?("_tinkick_key ") }
      pairs.join(", ")
    end

    def bucket(value, count)
      case value
      when true, false
        { "key" => value ? 1 : 0, "key_as_string" => value.to_s, "doc_count" => count }
      when Time
        { "key" => (value.to_r * 1_000).to_i, "key_as_string" => value.utc.iso8601(3), "doc_count" => count }
      when Date
        instant = Time.utc(value.year, value.month, value.day)
        { "key" => instant.to_i * 1_000, "key_as_string" => instant.iso8601(3), "doc_count" => count }
      when String, Numeric
        { "key" => value, "doc_count" => count }
      else
        raise InvalidQueryError, "Cannot aggregate #{value.class.name} values"
      end
    end
  end
end
