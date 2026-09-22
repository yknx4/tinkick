# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  class Aggregations
    module Metrics
      extend ActiveSupport::Concern

      private

      def calculate_metric(metric, field, conditions, missing: nil)
        # @type self: Aggregations
        scope = conditions ? Filter.new(@model).apply(@scope, conditions) : @scope
        values = values_relation(scope, field, unique: false, missing: missing)
        column = @model.columns_hash.fetch(field)
        unless metric == :cardinality || [:integer, :decimal, :float].include?(column.type)
          raise InvalidQueryError, "#{metric} requires a numeric aggregation column"
        end

        if metric == :cardinality
          Tinkick.warn(@model, "Tinkick: cardinality uses exact SQL COUNT(DISTINCT), which can cost more than an approximate estimate for many distinct values.")
          expression = "COUNT(DISTINCT _tinkick_value)"
        else
          expression = "#{metric.to_s.upcase}(_tinkick_value)"
        end
        query = @unscoped.from(values, :tinkick_values).select(Arel.sql(expression))
        # @type var value: Integer | Float | BigDecimal | nil
        value = @model.with_connection { |connection| connection.select_value(query) }
        # @type var result: aggregation_metric
        result = { "value" => metric == :cardinality ? (value || 0).to_i : value&.to_f }
        result["value"] = 0.0 if metric == :sum && value.nil?
        result["doc_count"] = scope.distinct.count(@model.primary_key) if conditions && !conditions.empty?
        result
      end
    end
  end
end
