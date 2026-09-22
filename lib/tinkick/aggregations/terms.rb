# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  class Aggregations
    module Terms
      extend ActiveSupport::Concern

      private

      def terms(field, options)
        # @type self: Aggregations
        limit = options.fetch(:limit, 1_000)
        minimum = options.fetch(:min_doc_count, 1)
        unless limit.is_a?(Integer) && limit.positive? && minimum.is_a?(Integer) && minimum >= 0
          raise ArgumentError, "Aggregation limit must be a positive integer and min_doc_count a nonnegative integer"
        end

        scope = @scope
        conditions = options[:where]
        scope = Filter.new(@model).apply(scope, conditions) if conditions
        values = values_relation(scope, field, missing: options[:missing])
        counts = @unscoped.from(values, :tinkick_values)
          .where(Arel.sql("_tinkick_value IS NOT NULL"))
          .group(Arel.sql("_tinkick_value"))
          .select(Arel.sql("_tinkick_value AS _tinkick_key, COUNT(*) AS _tinkick_count"))
        if minimum.zero?
          Tinkick.warn(@model, "Tinkick: min_doc_count: 0 reads the model's scoped term dictionary in addition to matching documents. This can cost more for many distinct values.")
          dictionary = @unscoped.from(values_relation(@dictionary_scope, field, missing: options[:missing]), :tinkick_values)
            .where(Arel.sql("_tinkick_value IS NOT NULL"))
            .select(Arel.sql("_tinkick_value AS _tinkick_key")).distinct
          counts = @unscoped.with(tinkick_dictionary: dictionary, tinkick_matching_counts: counts)
            .from("tinkick_dictionary")
            .joins("LEFT JOIN tinkick_matching_counts USING (_tinkick_key)")
            .select(Arel.sql("_tinkick_key, COALESCE(_tinkick_count, 0) AS _tinkick_count"))
        end
        query = @unscoped.from(counts, :tinkick_counts)
          .where(Arel.sql("_tinkick_count >= ?", minimum))
        query = term_filter(query, options.fetch(:include), exclude: false) if options.key?(:include)
        query = term_filter(query, options.fetch(:exclude), exclude: true) if options.key?(:exclude)
        query = query
          .select(Arel.sql("_tinkick_key, _tinkick_count, SUM(_tinkick_count) OVER () AS _tinkick_total"))
          .order(Arel.sql(order_sql(options.fetch(:order, { _count: :desc }))))
          .limit(limit)
        # @type var rows: Array[aggregation_term_row]
        rows = @model.with_connection { |connection| connection.select_all(query).to_a }
        # @type var buckets: Array[aggregation_bucket]
        buckets = rows.map { |row| bucket(row.fetch("_tinkick_key"), row.fetch("_tinkick_count").to_i) }
        total = rows.empty? ? 0 : rows.fetch(0).fetch("_tinkick_total").to_i
        # @type var bucket_count: Integer
        bucket_count = buckets.sum { |entry| entry.fetch("doc_count") }
        # @type var result: aggregation_terms
        result = { "doc_count_error_upper_bound" => 0, "sum_other_doc_count" => total - bucket_count, "buckets" => buckets }
        result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
        result
      end

      def term_filter(query, value, exclude:)
        # @type self: Aggregations
        case value
        when String
          Tinkick.warn(@model, "Tinkick: PostgreSQL regex aggregation include/exclude evaluates term values before selecting buckets. Use exact-value arrays when possible and inspect EXPLAIN ANALYZE for large dictionaries.")
          query.where(Arel.sql("_tinkick_key::text #{exclude ? "!~" : "~"} ?", value))
        when Array
          unless value.all? { |entry| entry.nil? || entry.is_a?(String) || entry.is_a?(Symbol) || entry.is_a?(Numeric) || entry.is_a?(Date) || entry.is_a?(Time) || entry == true || entry == false }
            raise ArgumentError, "Aggregation include/exclude arrays must contain scalar values"
          end
          values = value.compact.map { |entry| entry.is_a?(Symbol) ? entry.to_s : entry }
          return exclude ? query : query.none if values.empty?

          query.where(Arel.sql("_tinkick_key #{exclude ? "NOT IN" : "IN"} (?)", values))
        when Regexp
          raise NotImplementedError, "Aggregation include/exclude requires a native PostgreSQL regex string; Ruby Regexp sources and flags are not translated"
        when Hash
          raise NotImplementedError, "Elasticsearch terms partition hashing is not implemented; use an aggregation where: filter to partition rows with native PostgreSQL conditions"
        else
          raise ArgumentError, "Aggregation include/exclude must be an exact-value array or a native PostgreSQL regex string"
        end
      end

      def bucket(value, count)
        # @type self: Aggregations
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
end
