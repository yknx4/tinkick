# frozen_string_literal: true

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

        unknown = options.keys - [:field, :limit, :order, :min_doc_count, :where]
        raise ArgumentError, "Unknown aggregation options: #{unknown.join(", ")}" unless unknown.empty?

        [name.to_s, terms((options[:field] || name).to_s, options)]
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

    def values_relation(scope, field)
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
        if column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
          @model.logger&.warn("Tinkick: array aggregations expand matching array values in PostgreSQL before grouping. Use selective filters for frequent facets.")
          scope = scope.joins(Arel.sql("CROSS JOIN LATERAL unnest(#{value}) AS tinkick_elements(value)"))
          value = "tinkick_elements.value"
        end
        scope.select(Arel.sql("#{identifier} AS _tinkick_document_id, #{value} AS _tinkick_value")).distinct
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
