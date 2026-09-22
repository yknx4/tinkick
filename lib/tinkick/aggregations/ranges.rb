# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  class Aggregations
    module Ranges
      extend ActiveSupport::Concern

      private

      def range_buckets(ranges, date_values)
        # @type self: Aggregations
        ranges.map do |range|
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
          entry["from_as_string"] = lower_text if date_values && lower_text
          entry["to_as_string"] = upper_text if date_values && upper_text
          entry
        end.sort_by { |entry| [entry.fetch("from", -Float::INFINITY), entry.fetch("to", Float::INFINITY)] }
      end

      def keyed_range_bucket(entry)
        # @type self: Aggregations
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
        keyed_bucket
      end

      def range_aggregation(field, ranges, options, dates: false)
        # @type self: Aggregations
        raise ArgumentError, "ranges must be a nonempty array" unless ranges.is_a?(Array) && !ranges.empty?
        raise ArgumentError, "keyed must be true or false" unless [true, false].include?(options.fetch(:keyed, false))

        date_values = dates ? AggregationDate.new(format: options[:format], time_zone: options[:time_zone]) : nil
        buckets = range_buckets(ranges, date_values)
        conditions = options[:where]
        scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
        missing = date_values ? date_missing(field, options[:missing], date_values) : options[:missing]
        values = values_relation(scope, field, missing: missing)
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
        query = @unscoped.from(values, :tinkick_values).select(Arel.sql(selections.join(", "), *binds))
        # @type var counts: Hash[String, Integer]
        counts = @model.with_connection { |connection| connection.select_one(query) } || {}
        buckets.each_with_index { |entry, index| entry["doc_count"] = counts.fetch("_tinkick_range_#{index}", 0) }
        response_buckets = if options[:keyed]
          # @type var keyed_buckets: Hash[String, aggregation_keyed_range_bucket]
          keyed_buckets = {}
          buckets.each { |entry| keyed_buckets[entry.fetch("key")] = keyed_range_bucket(entry) }
          keyed_buckets
        else
          buckets
        end
        # @type var result: aggregation_ranges
        result = { "buckets" => response_buckets }
        result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
        result
      end
    end
  end
end
