# frozen_string_literal: true

require_relative "filter"

module Tinkick
  class Aggregations
    def initialize(model, scope)
      @model = model
      @scope = scope.except(:select, :order, :limit, :offset)
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
        unknown = options.keys - [:field, :limit, :order, :min_doc_count, :where, *metric_names]
        raise ArgumentError, "Unknown aggregation options: #{unknown.join(", ")}" unless unknown.empty?

        metrics = metric_names.select { |metric| options.key?(metric) }
        raise ArgumentError, "Each aggregation must select only one metric" if metrics.length > 1

        result = if metrics.empty?
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

    def terms(field, options)
      limit = options.fetch(:limit, 1_000)
      minimum = options.fetch(:min_doc_count, 1)
      unless limit.is_a?(Integer) && limit.positive? && minimum.is_a?(Integer) && minimum.positive?
        raise ArgumentError, "Aggregation limit and min_doc_count must be positive integers"
      end

      scope = @scope
      conditions = options[:where]
      scope = Filter.new(@model).apply(scope, conditions) if conditions
      values = values_relation(scope, field)
      counts = @model.unscoped.from(values, :tinkick_values)
        .where(Arel.sql("_tinkick_value IS NOT NULL"))
        .group(Arel.sql("_tinkick_value"))
        .select(Arel.sql("_tinkick_value AS _tinkick_key, COUNT(*) AS _tinkick_count"))
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
