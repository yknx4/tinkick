# frozen_string_literal: true

module Tinkick
  class BoostBy
    MAX_SCORE = 3.4028234663852886e38

    def initialize(model, specification)
      @model = model
      @sums = [] #: Array[[String, String]]
      @multipliers = [] #: Array[[String, String]]
      @warned = false
      return unless specification

      fields = if specification.is_a?(Array)
        specification.to_h { |field| [field, {}] }
      else
        specification
      end #: Hash[String | Symbol, numeric_boost_options]
      raise ArgumentError, "boost_by must be an array of numeric fields or a field options hash" unless fields.is_a?(Hash)

      fields.each do |name, options|
        unless options.is_a?(Hash) && (options.keys - [:factor, :modifier, :missing, :boost_mode]).empty?
          raise ArgumentError, "boost_by field options must contain only factor, modifier, missing, and boost_mode"
        end
        multiply = options[:boost_mode] == "multiply"
        modifier = options.fetch(:modifier, multiply ? "none" : "ln2p").to_s.downcase
        factor = number(options.fetch(:factor, 1))
        value = numeric_field(name.to_s)
        replacement = options[:missing]
        value = "COALESCE(#{value}, #{number(replacement)})" if replacement
        present = replacement ? "TRUE" : "#{value} IS NOT NULL"
        score = modified("(#{value} * #{factor})", modifier)
        checked = <<~SQL.squish
          CASE WHEN (#{score}) >= 0 AND (#{score}) <> 'NaN'::numeric
            THEN (#{score})
            ELSE ('boost_by produced a negative or NaN score: ' || (#{score})::text)::numeric
          END
        SQL
        (multiply ? @multipliers : @sums) << [present, checked]
      end
    end

    def empty?
      @sums.empty? && @multipliers.empty?
    end

    def score_sql(base_score)
      return base_score if empty?

      unless @warned
        @model.logger&.warn("Tinkick: numeric boost_by scoring evaluates numeric fields for matching rows and can sort results instead of using native TIN top-k. Numeric arrays also inspect values per row. Inspect EXPLAIN ANALYZE with representative data before using this on large result sets.")
        @warned = true
      end
      "((#{base_score})::double precision * #{group(@sums, '+')} * #{group(@multipliers, '*')})"
    end

    private

    def number(value)
      unless value.nil? || value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal) || value.is_a?(String)
        raise ArgumentError, "boost_by factor and missing values must be finite numbers or numeric strings"
      end
      result = value.to_f
      raise ArgumentError, "boost_by factor and missing values must be finite" unless result.finite?

      result
    end

    def numeric_field(name)
      column = @model.columns_hash[name]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{name.inspect}; add a numeric column with a Rails migration before using boost_by"
      end
      unless [:integer, :float, :decimal].include?(column.type)
        raise ArgumentError, "boost_by field #{name.inspect} must be a numeric PostgreSQL column or numeric array"
      end

      @model.with_connection do |connection|
        field = "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
        if column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
          field = "(SELECT MIN(tinkick_boost_value) FROM unnest(#{field}) AS tinkick_boost_values(tinkick_boost_value))"
        end
        "(#{field})::numeric"
      end
    end

    def modified(value, modifier)
      case modifier
      when "none" then value
      when "log" then "log(#{value})"
      when "log1p" then "log(1.0 + #{value})"
      when "log2p" then "log(2.0 + #{value})"
      when "ln" then "ln(#{value})"
      when "ln1p" then "ln(1.0 + #{value})"
      when "ln2p" then "ln(2.0 + #{value})"
      when "square" then "power(#{value}, 2)"
      when "sqrt" then "sqrt(#{value})"
      when "reciprocal" then "(CASE WHEN #{value} = 0 THEN 'Infinity'::numeric ELSE 1.0 / #{value} END)"
      else raise ArgumentError, "Unsupported boost_by modifier: #{modifier.inspect}"
      end
    end

    def group(functions, operation)
      return "1.0" if functions.empty?

      identity = operation == "+" ? "0.0" : "1.0"
      combined = functions.map { |present, score| "(CASE WHEN #{present} THEN (#{score}) ELSE #{identity} END)" }.join(" #{operation} ")
      if operation == "+"
        present = functions.map { |condition, _score| "(#{condition})" }.join(" OR ")
        combined = "CASE WHEN #{present} THEN (#{combined}) ELSE 1.0 END"
      end
      "LEAST((#{combined}), #{MAX_SCORE})::double precision"
    end
  end
end
