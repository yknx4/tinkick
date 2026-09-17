# frozen_string_literal: true

require "json"
require_relative "regex_pattern"

module Tinkick
  class Filter
    def initialize(model)
      @model = model
    end

    def apply(scope, conditions)
      sql, binds = combine(predicates(conditions), "AND")
      scope.where(Arel.sql(sql, *binds))
    end

    private

    def predicates(conditions)
      raise ArgumentError, "where conditions must be a hash" unless conditions.is_a?(Hash)

      conditions.flat_map do |field, value|
        case field
        when :or
          raise ArgumentError, "or requires an array of alternative groups" unless value.is_a?(Array)

          value.map do |alternatives|
            raise ArgumentError, "or requires an array of alternative groups" unless alternatives.is_a?(Array)

            combine(alternatives.map { |entry| combine(predicates(entry), "AND") }, "OR")
          end
        when :_and, :_or
          raise ArgumentError, "#{field} requires an array of condition hashes" unless value.is_a?(Array)

          groups = value.map { |entry| combine(predicates(entry), "AND") }
          [combine(groups, field == :_and ? "AND" : "OR")]
        when :_not
          predicates(value).map { |predicate| negate(predicate) }
        else
          column, array_type, json_path = column_reference(field)
          if json_path
            json_predicates(column, json_path, value)
          else
            field_predicates(column, value, array_type: array_type)
          end
        end
      end
    end

    def column_reference(field)
      parts = field.to_s.split(".", -1)
      name = parts.fetch(0, "")
      path = parts.drop(1)
      column = @model.columns_hash[name]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{name.inspect}; add it with a Rails migration before filtering"
      end
      if column.type == :json
        raise InvalidQueryError, "Filtering #{name.inspect} requires a JSONB column; convert it with a Rails migration"
      end
      array_type = "#{column.sql_type}[]" if column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
      if column.type == :jsonb && !array_type
        raise ArgumentError, "JSONB paths require non-empty components" if path.any?(&:empty?)

        json_path = "$#{path.map { |part| ".#{JSON.generate(part)}" }.join}[*]"
      elsif !path.empty?
        raise InvalidQueryError, "Dotted filter #{field.inspect} requires a JSONB root column"
      end

      reference = @model.with_connection do |connection|
        "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
      end
      [reference, array_type, json_path]
    end

    def json_predicates(column, path, value)
      if value.is_a?(Range)
        # @type var bounds: Hash[String | Symbol, filter_value]
        bounds = {}
        lower = value.begin
        upper = value.end
        bounds[:gte] = lower if lower && lower != -Float::INFINITY
        bounds[value.exclude_end? ? :lt : :lte] = upper if upper && upper != Float::INFINITY
        return json_predicates(column, path, bounds)
      end
      return [json_equality(column, path, value)] unless value.is_a?(Hash)

      # @type var comparisons: Array[String]
      comparisons = []
      filters = value.flat_map do |operator, operand|
        case operator
        when :in
          [json_equality(column, path, operand)]
        when :all
          raise ArgumentError, "all requires an array of values" unless operand.is_a?(Array)

          operand.map { |entry| json_equality(column, path, entry) }
        when :not, :_not
          [negate(json_equality(column, path, operand))]
        when :exists
          unless operand == true || operand == false
            raise ArgumentError, "Passing a value other than true or false to exists is not supported"
          end
          missing = json_equality(column, path, nil)
          [operand ? negate(missing) : missing]
        when :like, :ilike, :prefix
          [json_text_predicate(column, path, operator, operand)]
        when :gt, :gte, :lt, :lte
          comparison = { gt: ">", gte: ">=", lt: "<", lte: "<=" }.fetch(operator)
          comparisons << "@ #{comparison} #{JSON.generate(scalar(operand))}"
          []
        else
          raise ArgumentError, "Unknown where operator: #{operator.inspect}"
        end
      end
      unless comparisons.empty?
        warn_json_scan(column)
        filters << json_match(column, path, comparisons.join(" && "))
      end
      filters
    end

    def json_equality(column, path, value)
      return json_text_predicate(column, path, :regexp, value) if value.is_a?(Regexp)

      if value.is_a?(Array)
        return ["FALSE", []] if value.empty?

        combine(value.map { |entry| json_equality(column, path, entry) }, "OR")
      elsif value.nil?
        warn_json_scan(column)
        negate(json_match(column, path, '@.type() != "null" && @.type() != "array" && @.type() != "object"'))
      else
        json_match(column, path, "@ == #{JSON.generate(scalar(value))}")
      end
    end

    def json_match(column, path, condition)
      ["#{column} @@ ?::jsonpath", ["exists(#{path} ? (#{condition}))"]]
    end

    def json_text_predicate(column, path, operator, value)
      sql, binds = text_predicate("tinkick_filter_element.value #>> '{}'", operator, value)
      warn_json_scan(column)
      ["EXISTS (SELECT 1 FROM jsonb_path_query(#{column}, ?::jsonpath) AS tinkick_filter_element(value) WHERE jsonb_typeof(tinkick_filter_element.value) = 'string' AND #{sql})", [path, *binds]]
    end

    def warn_json_scan(column)
      @model.logger&.warn("Tinkick: this JSONB filter scans values in #{column}; ordinary GIN indexes cannot extract selective equality keys for range, pattern, or missing-value checks. Consider an indexed persisted or generated scalar column for frequent filters.")
    end

    def field_predicates(column, value, array_type: nil)
      element = array_type ? "tinkick_filter_element.value" : column
      case value
      when Range
        [element_predicate(column, range_predicate(element, value), array_type)]
      when Hash
        # @type var comparisons: Array[filter_predicate]
        comparisons = []
        filters = value.flat_map do |operator, operand|
          case operator
          when :in
            [equality(column, operand, array_type: array_type)]
          when :all
            raise ArgumentError, "all requires an array of values" unless operand.is_a?(Array)

            operand.map { |entry| equality(column, entry, array_type: array_type) }
          when :exists
            [existence(column, operand, array_type: array_type)]
          when :like, :ilike, :prefix
            [element_predicate(column, text_predicate(element, operator, operand), array_type)]
          when :not, :_not
            [negate(equality(column, operand, array_type: array_type))]
          when :gt, :gte, :lt, :lte
            comparisons << comparison(element, operator, operand)
            []
          else
            raise ArgumentError, "Unknown where operator: #{operator.inspect}"
          end
        end
        filters << element_predicate(column, combine(comparisons, "AND"), array_type) unless comparisons.empty?
        filters
      else
        [equality(column, value, array_type: array_type)]
      end
    end

    def equality(column, value, array_type: nil)
      if value.is_a?(Regexp)
        element = array_type ? "tinkick_filter_element.value" : column
        return element_predicate(column, text_predicate(element, :regexp, value), array_type)
      end
      if value.is_a?(Array)
        return ["FALSE", []] if value.empty?

        combine(value.map { |entry| equality(column, entry, array_type: array_type) }, "OR")
      elsif value.nil?
        if array_type
          negate(element_predicate(column, ["tinkick_filter_element.value IS NOT NULL", []], array_type))
        else
          ["#{column} IS NULL", []]
        end
      elsif array_type
        ["#{column} @> ARRAY[?]::#{array_type}", [scalar(value)]]
      else
        ["#{column} = ?", [scalar(value)]]
      end
    end

    def existence(column, value, array_type: nil)
      case value
      when TrueClass
        negate(equality(column, nil, array_type: array_type))
      when FalseClass
        equality(column, nil, array_type: array_type)
      else
        raise ArgumentError, "Passing a value other than true or false to exists is not supported"
      end
    end

    def element_predicate(column, predicate, array_type)
      return predicate unless array_type

      @model.logger&.warn("Tinkick: this filter scans array elements for #{column}; ordinary GIN array indexes cannot accelerate range, pattern, or missing-value checks. Consider a persisted or generated scalar column with an appropriate index for frequent filters.")
      sql, binds = predicate
      ["EXISTS (SELECT 1 FROM unnest(#{column}) AS tinkick_filter_element(value) WHERE #{sql})", binds]
    end

    def text_predicate(column, operator, value)
      if operator == :regexp && value.is_a?(Regexp)
        @model.logger&.warn("Tinkick: regular expression filters can scan column values outside TIN. Use selective search/where conditions and inspect EXPLAIN; an optional pg_trgm expression index may help suitable patterns.")
        return ["(#{column})::text COLLATE \"C\" ~ ?", [RegexPattern.new(value).compile]]
      end
      raise TypeError, "#{operator} requires a string" unless value.is_a?(String)

      if operator == :prefix
        ["#{column} ^@ ?", [value]]
      else
        # Searchkick only treats a backslash as an escape before % and _.
        pattern = value.gsub(/\\(?![%_])/) { "\\\\" }
        sql_operator = operator == :ilike ? "ILIKE" : "LIKE"
        ["#{column} #{sql_operator} ? ESCAPE ?", [pattern, "\\"]]
      end
    end

    def comparison(column, operator, value)
      sql_operator = { gt: ">", gte: ">=", lt: "<", lte: "<=" }.fetch(operator)
      ["#{column} #{sql_operator} ?", [scalar(value)]]
    end

    def range_predicate(column, range)
      # @type var comparisons: Array[filter_predicate]
      comparisons = []
      lower = range.begin
      upper = range.end
      comparisons << comparison(column, :gte, lower) if lower && lower != -Float::INFINITY
      comparisons << comparison(column, range.exclude_end? ? :lt : :lte, upper) if upper && upper != Float::INFINITY
      combine(comparisons, "AND")
    end

    def scalar(value)
      case value
      when String, Symbol, Numeric, Date, Time, TrueClass, FalseClass, NilClass
        value
      else
        raise TypeError, "can't cast #{value.class.name}"
      end
    end

    def negate(predicate)
      sql, binds = predicate
      ["(#{sql}) IS NOT TRUE", binds]
    end

    def combine(predicates, operator)
      return ["TRUE", []] if predicates.empty?

      sql = predicates.map { |predicate| "(#{predicate.first})" }.join(" #{operator} ")
      [sql, predicates.flat_map(&:last)]
    end
  end
end
