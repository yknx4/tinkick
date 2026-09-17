# frozen_string_literal: true

require_relative "aggregation_date"

module Tinkick
  class RecencyBoost
    MAX_WEIGHT = 3.4028234663852886e38
    MAX_MILLISECONDS = 9_223_372_036_854_775_807
    TIME_UNITS = { "nanos" => Rational(1, 1_000_000), "micros" => Rational(1, 1_000), "ms" => 1, "s" => 1_000,
      "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000 }.freeze

    attr_reader :weights

    def initialize(model, specification, now: Time.now)
      @model = model
      @now = now
      @functions = [] #: Array[[String, String]]
      @weights = [] #: Array[Float]
      @warned = false
      return unless specification
      raise ArgumentError, "boost_by_recency must be a field options hash" unless specification.is_a?(Hash)

      specification.each do |name, options|
        unless options.is_a?(Hash) && (options.keys - [:function, :origin, :scale, :offset, :decay, :factor]).empty?
          raise ArgumentError, "boost_by_recency field options must contain only function, origin, scale, offset, decay, and factor"
        end
        weight = weight(options[:factor] || 1)
        @weights << weight
        @functions << ["TRUE", "(#{compile(name.to_s, options)} * #{weight})"]
      end
    end

    def empty?
      @functions.empty?
    end

    def functions
      unless empty? || @warned
        @model.logger&.warn("Tinkick: boost_by_recency scoring evaluates fields for matching rows and can sort results instead of using native TIN top-k. Date and numeric arrays also inspect values per row. Inspect EXPLAIN ANALYZE with representative data before using this on large result sets.")
        @warned = true
      end
      @functions
    end

    private

    def compile(name, options)
      column = @model.columns_hash[name]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{name.inspect}; add a date or numeric column with a Rails migration before using boost_by_recency"
      end
      date = [:date, :datetime].include?(column.type)
      unless date || [:integer, :float, :decimal].include?(column.type)
        raise ArgumentError, "boost_by_recency field #{name.inspect} must be a date or numeric PostgreSQL column or array"
      end
      function = options.fetch(:function, :gauss).to_s
      unless ["gauss", "exp", "linear"].include?(function)
        raise ArgumentError, "boost_by_recency function must be gauss, exp, or linear"
      end
      decay = number(options.fetch(:decay, 0.5), "decay")
      raise ArgumentError, "boost_by_recency decay must be greater than 0 and less than 1" unless decay.positive? && decay < 1

      origin = if date
        date_origin(options.fetch(:origin, @now))
      else
        number(options[:origin], "numeric origin")
      end
      scale = date ? duration(options[:scale], "scale") : number(options[:scale], "scale")
      offset = date ? duration(options.fetch(:offset, "0d"), "offset") : number(options.fetch(:offset, 0), "offset")
      raise ArgumentError, "boost_by_recency scale must be positive" unless scale.positive?
      raise ArgumentError, "boost_by_recency offset must be nonnegative" if offset.negative?

      ratio = "(#{distance(name, column, origin, offset, date: date)} / #{scale})"
      return "GREATEST(0.0, 1.0 - #{1 - decay} * #{ratio})" if function == "linear"

      exponent = "(#{Math.log(decay)} * #{ratio}#{" * #{ratio}" if function == "gauss"})"
      # Java's exp returns zero below the representable range; PostgreSQL raises.
      "CASE WHEN #{exponent} < -745 THEN 0.0 ELSE exp((#{exponent})::double precision) END"
    end

    def date_origin(value)
      raise ArgumentError, "boost_by_recency date origin cannot be nil" if value.nil?

      # DecayFunctionBuilder reads numeric JSON origins as text before date parsing.
      value = value.to_s if value.is_a?(Numeric)
      result = AggregationDate.new(now: @now).parse(value)
      unless result && result.finite? && result.between?(-MAX_MILLISECONDS - 1, MAX_MILLISECONDS)
        raise ArgumentError, "boost_by_recency date origin must fit in signed 64-bit epoch milliseconds"
      end
      result.floor
    end

    def duration(value, name)
      text = value.to_s.strip
      return 0 if /\A0+\z/.match?(text)

      match = /\A([+-]?[0-9]+)\s*(nanos|micros|ms|s|m|h|d)\z/i.match(text)
      unless match && !text.end_with?("M")
        raise ArgumentError, "boost_by_recency #{name} requires an integer time unit: nanos, micros, ms, s, m, h, or d"
      end
      amount = Integer(match[1].to_s, 10)
      unless amount.between?(-1, MAX_MILLISECONDS)
        raise ArgumentError, "boost_by_recency #{name} duration must be nonnegative and fit in a signed 64-bit integer"
      end
      # Elasticsearch TimeValue truncates submilliseconds and saturates conversion.
      unit = TIME_UNITS.fetch(match[2].to_s.downcase)
      converted = unit.is_a?(Rational) ? (amount * unit).to_i : amount * unit
      [converted, MAX_MILLISECONDS].min
    end

    def number(value, name)
      unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal) || value.is_a?(String)
        raise ArgumentError, "boost_by_recency #{name} must be a finite number or numeric string"
      end
      result = Float(value)
      raise ArgumentError, "boost_by_recency #{name} must be finite" unless result.finite?

      result
    rescue ArgumentError, TypeError
      raise ArgumentError, "boost_by_recency #{name} must be a finite number or numeric string"
    end

    def weight(value)
      result = number(value, "factor")
      if result.negative? || (result.zero? && (1.0 / result).negative?)
        raise ArgumentError, "boost_by_recency factor must be nonnegative"
      end
      [result, MAX_WEIGHT].min
    end

    def distance(name, column, origin, offset, date:)
      @model.with_connection do |connection|
        field = "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
        array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
        value = array ? "tinkick_recency_value" : field
        value = date ? "floor(extract(epoch FROM #{value}) * 1000)" : "(#{value})::numeric"
        distance = "GREATEST(0.0, abs(#{value} - #{origin}) - #{offset})"
        if array
          distance = "(SELECT MIN(#{distance}) FROM unnest(#{field}) AS tinkick_recency_values(tinkick_recency_value) WHERE tinkick_recency_value IS NOT NULL)"
        end
        "COALESCE(#{distance}, 0.0)"
      end
    end
  end
end
