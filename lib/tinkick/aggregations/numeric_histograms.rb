# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  class Aggregations
    module NumericHistograms
      extend ActiveSupport::Concern

      private

      def numeric_histogram(field, options, conditions)
        # @type self: Aggregations
        unknown = options.keys - [:field, :interval, :offset, :min_doc_count, :order, :keyed, :extended_bounds, :hard_bounds, :missing]
        raise ArgumentError, "Unknown histogram options: #{unknown.join(", ")}" unless unknown.empty?

        interval = numeric_bound(options[:interval])
        offset = numeric_bound(options.fetch(:offset, 0))
        raise ArgumentError, "Histogram interval must be positive and offset must be numeric" unless interval && interval.positive? && offset

        minimum = options.fetch(:min_doc_count, 0)
        raise ArgumentError, "Histogram min_doc_count must be a nonnegative integer" unless minimum.is_a?(Integer) && minimum >= 0
        raise ArgumentError, "Histogram keyed must be true or false" unless [true, false].include?(options.fetch(:keyed, false))
        # @type var default_bounds: aggregation_histogram_bounds
        default_bounds = {}
        extended_min, extended_max = histogram_bounds(options.fetch(:extended_bounds, default_bounds))
        hard_min, hard_max = histogram_bounds(options.fetch(:hard_bounds, default_bounds))
        if (extended_min && hard_min && extended_min < hard_min) || (extended_max && hard_max && extended_max > hard_max)
          raise ArgumentError, "Extended bounds must be within hard bounds"
        end

        scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
        values = values_relation(scope, field, missing: options[:missing])
        unless [:integer, :decimal, :float].include?(@model.columns_hash.fetch(field).type)
          raise InvalidQueryError, "histogram requires a numeric aggregation column"
        end
        ordinals = @unscoped.from(values, :tinkick_values)
          .where(Arel.sql("_tinkick_value IS NOT NULL"))
          .select(Arel.sql("FLOOR((_tinkick_value::double precision - ?) / ?) AS _tinkick_ordinal, _tinkick_document_id", offset, interval))
        counts = @unscoped.from(ordinals, :tinkick_ordinals)
          .group(Arel.sql("_tinkick_ordinal"))
          .select(Arel.sql("_tinkick_ordinal, COUNT(DISTINCT _tinkick_document_id) AS _tinkick_count"))
        # Elasticsearch checks numeric hard bounds before adding the histogram offset.
        counts = counts.where(Arel.sql("_tinkick_ordinal * ? >= ?", interval, hard_min)) if hard_min
        counts = counts.where(Arel.sql("_tinkick_ordinal * ? <= ?", interval, hard_max)) if hard_max
        query = numeric_histogram_query(counts, minimum, interval, offset, extended_min, extended_max)
        query = query.order(Arel.sql(order_sql(options.fetch(:order, { _key: :asc }))))
        # @type var rows: Array[aggregation_histogram_row]
        rows = @model.with_connection { |connection| connection.select_all(query).to_a }
        # @type var buckets: Array[aggregation_histogram_bucket]
        buckets = rows.map { |row| { "key" => row.fetch("_tinkick_key"), "doc_count" => row.fetch("_tinkick_count") } }
        # @type var result: aggregation_histogram
        result = { "buckets" => options[:keyed] ? keyed_numeric_buckets(buckets) : buckets }
        result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
        result
      end

      def keyed_numeric_buckets(buckets)
        # @type var keyed: Hash[String, aggregation_histogram_bucket]
        keyed = {}
        buckets.each { |bucket| keyed[bucket.fetch("key").to_s] = bucket }
        keyed
      end

      def numeric_histogram_query(counts, minimum, interval, offset, extended_min, extended_max)
        # @type self: Aggregations
        if minimum.zero?
          Tinkick.warn(@model, "Tinkick: histogram min_doc_count: 0 generates empty buckets across the matching numeric range. Small intervals over wide ranges can produce many buckets; use min_doc_count: 1 when empty buckets are unnecessary.")
          lower = extended_min && ((extended_min - offset) / interval).floor
          upper = extended_max && ((extended_max - offset) / interval).floor
          bounds = @unscoped.from("tinkick_histogram_counts")
            .select(Arel.sql("LEAST(MIN(_tinkick_ordinal), ?)::numeric AS lower, GREATEST(MAX(_tinkick_ordinal), ?)::numeric AS upper", lower, upper))
          @unscoped.with(tinkick_histogram_counts: counts)
            .from(bounds, :tinkick_bounds)
            .joins("CROSS JOIN LATERAL generate_series(lower, upper, 1) AS tinkick_series(_tinkick_ordinal)")
            .joins("LEFT JOIN tinkick_histogram_counts USING (_tinkick_ordinal)")
            .select(Arel.sql("_tinkick_ordinal::double precision * ? + ? AS _tinkick_key, COALESCE(_tinkick_count, 0) AS _tinkick_count", interval, offset))
        else
          @unscoped.from(counts, :tinkick_histogram_counts)
            .where(Arel.sql("_tinkick_count >= ?", minimum))
            .select(Arel.sql("_tinkick_ordinal * ? + ? AS _tinkick_key, _tinkick_count", interval, offset))
        end
      end

      def histogram_bounds(bounds)
        # @type self: Aggregations
        unless bounds.is_a?(Hash) && (bounds.keys - [:min, :max]).empty?
          raise ArgumentError, "Histogram bounds must be a hash containing only min and max"
        end

        lower = numeric_bound(bounds[:min])
        upper = numeric_bound(bounds[:max])
        raise ArgumentError, "Histogram bounds max must be greater than or equal to min" if lower && upper && upper < lower

        [lower, upper]
      end
    end
  end
end
