# frozen_string_literal: true

require_relative "filter"
require_relative "aggregation_date"
require_relative "aggregations/date_histograms"
require_relative "aggregations/numeric_histograms"
require_relative "aggregations/ranges"
require_relative "aggregations/terms"
require_relative "aggregations/metrics"

module Tinkick
  class Aggregations
    include Metrics
    include Terms
    include Ranges
    include NumericHistograms
    include DateHistograms

    def initialize(model, scope, dictionary_scope: model.all)
      @model = model
      # STI conditions belong in the inner search, not derived-table wrappers.
      @unscoped = model.unscoped.unscope(:where)
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
        metrics = validate_options(options)
        result = aggregate(name, options, metrics)
        [name.to_s, result]
      end
    end

    private

    def validate_options(options)
      raise ArgumentError, "Aggregation options must be a hash" unless options.is_a?(Hash)

      # @type var metric_names: Array[aggregation_metric_name]
      metric_names = [:avg, :cardinality, :max, :min, :sum]
      unknown = options.keys - [:field, :limit, :order, :min_doc_count, :where, :ranges, :date_ranges, :histogram, :date_histogram, :keyed, :time_zone, :format, :include, :exclude, :missing, *metric_names]
      raise ArgumentError, "Unknown aggregation options: #{unknown.join(", ")}" unless unknown.empty?

      metrics = metric_names.select { |metric| options.key?(metric) }
      raise ArgumentError, "Each aggregation must select only one metric" if metrics.length > 1
      range_kinds = [:ranges, :date_ranges].select { |kind| options.key?(kind) }
      histogram_kinds = [:histogram, :date_histogram].select { |kind| options.key?(kind) }
      if range_kinds.length + metrics.length + histogram_kinds.length > 1
        raise ArgumentError, "Each aggregation must select only one range kind, histogram, or metric"
      end
      if (options.key?(:include) || options.key?(:exclude)) && (range_kinds.any? || metrics.any? || histogram_kinds.any?)
        raise ArgumentError, "include and exclude apply only to terms aggregations"
      end
      if options.key?(:missing) && (metrics.any? || histogram_kinds.any?)
        raise ArgumentError, "Top-level missing applies only to terms and ranges; put metric or histogram defaults inside their options hash"
      end
      raise ArgumentError, "keyed applies only to range aggregations" if options.key?(:keyed) && range_kinds.empty?
      raise ArgumentError, "time_zone applies only to date aggregations" if options.key?(:time_zone) && !options.key?(:date_ranges)
      if options.key?(:format) && !options.key?(:date_ranges) && !options.key?(:date_histogram)
        raise ArgumentError, "format applies only to date aggregations"
      end

      metrics
    end

    def aggregate(name, options, metrics)
      if options.key?(:date_histogram)
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
        metric_options = options.fetch(metric) #: aggregation_metric_options
        unless metric_options.is_a?(Hash) && (metric_options.keys - [:field, :missing]).empty?
          raise ArgumentError, "Metric options must be a hash containing field and/or missing"
        end
        calculate_metric(metric, (metric_options[:field] || name).to_s, options[:where], missing: metric_options[:missing])
      end
    end

    def date_missing(field, value, formatter)
      return if value.nil?
      unless value.is_a?(Numeric) || value.is_a?(String) || value.is_a?(Date) || value.is_a?(Time)
        raise ArgumentError, "Missing date values must be Date, Time, ISO8601 strings, or epoch milliseconds"
      end

      milliseconds = formatter.parse(value)
      return unless milliseconds

      instant = Time.at(Rational(milliseconds.to_s) / 1_000).utc
      return instant unless @model.columns_hash[field]&.type == :date

      case value
      when Date, Time then value.to_date
      when String
        Integer(value, 10, exception: false) ? instant.to_date : Date.iso8601(value)
      else instant.to_date
      end
    end

    def numeric_bound(value)
      return if value.nil?

      number = Float(value)
      raise ArgumentError, "Range bounds must be finite numbers" unless number.is_a?(Float) && number.finite?

      number
    rescue TypeError
      raise ArgumentError, "Range bounds must be finite numbers"
    end

    def values_relation(scope, field, unique: true, missing: nil)
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
          Tinkick.warn(@model, "Tinkick: array aggregations expand matching array values in PostgreSQL before calculating buckets or metrics. Use selective filters for frequent facets.")
          join = "LATERAL unnest(tinkick_documents._tinkick_value) AS tinkick_elements(value)"
          elements = if missing.nil?
            @unscoped.from(documents, :tinkick_documents).joins(Arel.sql("CROSS JOIN #{join}"))
              .select(Arel.sql("_tinkick_document_id, tinkick_elements.value AS _tinkick_value"))
          else
            @unscoped.from(documents, :tinkick_documents)
              .joins(Arel.sql("LEFT JOIN #{join} ON tinkick_elements.value IS NOT NULL"))
              .select(Arel.sql("_tinkick_document_id, COALESCE(tinkick_elements.value, ?) AS _tinkick_value", missing))
          end
          unique ? elements.distinct : elements
        else
          missing.nil? ? documents : scope.select(Arel.sql("#{identifier} AS _tinkick_document_id, COALESCE(#{value}, ?) AS _tinkick_value", missing)).distinct
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
  end
end
