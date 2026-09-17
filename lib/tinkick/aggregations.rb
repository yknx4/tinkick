# frozen_string_literal: true

require_relative "filter"

module Tinkick
  class Aggregations
    def initialize(model, scope, dictionary_scope: model.all)
      @model = model
      @scope = scope.except(:select, :order, :limit, :offset)
      @dictionary_scope = dictionary_scope.except(:select, :order, :limit, :offset)
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
        unknown = options.keys - [:field, :limit, :order, :min_doc_count, :where, :ranges, :date_ranges, :keyed, *metric_names]
        raise ArgumentError, "Unknown aggregation options: #{unknown.join(", ")}" unless unknown.empty?

        metrics = metric_names.select { |metric| options.key?(metric) }
        raise ArgumentError, "Each aggregation must select only one metric" if metrics.length > 1
        range_kinds = [:ranges, :date_ranges].select { |kind| options.key?(kind) }
        raise ArgumentError, "Each aggregation must select only one range kind or metric" if range_kinds.length + metrics.length > 1
        raise ArgumentError, "keyed applies only to range aggregations" if options.key?(:keyed) && range_kinds.empty?

        result = if options.key?(:date_ranges)
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

      buckets = ranges.map do |range|
        unless range.is_a?(Hash) && (range.keys - [:from, :to, :key]).empty?
          raise ArgumentError, "Each range must contain only from, to, or key"
        end
        lower = dates ? date_bound(range[:from]) : numeric_bound(range[:from])
        upper = dates ? date_bound(range[:to]) : numeric_bound(range[:to])
        lower_text = dates && lower ? date_string(lower) : lower&.to_s
        upper_text = dates && upper ? date_string(upper) : upper&.to_s
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

    def date_bound(value)
      return if value.nil?
      return numeric_bound(value) if value.is_a?(Numeric)

      instant = case value
      when Time then value
      when DateTime then value.to_time
      when Date then Time.utc(value.year, value.month, value.day)
      when String
        parsed_date = Date.iso8601(value)
        if /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
          Time.utc(parsed_date.year, parsed_date.month, parsed_date.day)
        else
          suffix = /(?:Z|[+-]\d{2}(?::?\d{2})?)\z/i.match?(value) ? "" : "Z"
          Time.iso8601(value + suffix)
        end
      else
        raise ArgumentError, "Date range bounds must be Date, Time, ISO8601 strings, or epoch milliseconds"
      end
      (instant.to_r * 1_000).to_f
    end

    def date_string(value)
      Time.at(Rational(value.to_s) / 1_000).utc.iso8601(3)
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
