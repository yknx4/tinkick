# frozen_string_literal: true

require "json"

module Tinkick
  class Filter
    def initialize(model)
      @model = model
    end

    def apply(scope, conditions)
      sql, binds = predicate(conditions)
      scope.where(Arel.sql(sql, *binds))
    end

    def predicate(conditions)
      combine(predicates(conditions), "AND")
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
          column, array_type, json_path, enum_values = column_reference(field)
          if json_path
            json_predicates(column, json_path, value)
          else
            field_predicates(column, value, array_type: array_type, enum_values: enum_values)
          end
        end
      end
    end

    def column_reference(field)
      name = field.to_s
      if name == "id"
        primary_key = @model.primary_key
        raise InvalidQueryError, "Filtering by id requires a single model primary key" unless primary_key.is_a?(String)

        name = primary_key
      end
      parts = name.split(".", -1)
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

        json_path = path
      elsif !path.empty?
        raise InvalidQueryError, "Dotted filter #{field.inspect} requires a JSONB root column"
      end

      reference = @model.with_connection do |connection|
        "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
      end
      # @type var enum_values: Hash[String, filter_scalar]?
      enum_values = @model.defined_enums[name] if path.empty?
      enum_values = enum_values.select { |label, stored| enum_values&.key(stored) == label } if enum_values
      [reference, array_type, json_path, enum_values]
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
        when :like, :ilike, :prefix, :regexp
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
        negate(json_match(column, path, '@.type() != "null" && @.type() != "array" && @.type() != "object"', descendants: true))
      else
        condition = "@ == #{JSON.generate(scalar(value))}"
        # @type var candidate: filter_predicate
        candidate = ["#{column} @@ ?::jsonpath", ["exists($.** ? (#{condition}))"]]
        combine([candidate, json_match(column, path, condition)], "AND")
      end
    end

    def json_match(column, path, condition, descendants: false)
      values, binds = json_values(column, path, descendants: descendants)
      ["EXISTS (SELECT 1 FROM (#{values}) AS tinkick_filter_element(value) WHERE value @@ ?::jsonpath)",
        [*binds, "strict exists($ ? (#{condition}))"]]
    end

    def json_text_predicate(column, path, operator, value)
      sql, binds = text_predicate("tinkick_filter_element.value #>> '{}'", operator, value)
      warn_json_scan(column)
      values, path_binds = json_values(column, path)
      ["EXISTS (SELECT 1 FROM (#{values}) AS tinkick_filter_element(value) WHERE jsonb_typeof(tinkick_filter_element.value) = 'string' AND #{sql})", [*path_binds, *binds]]
    end

    def json_values(column, path, descendants: false)
      Tinkick.warn(@model, "Tinkick: JSONB filters verify recursive array paths per candidate row. A jsonb_ops GIN index can narrow equality candidates; jsonb_path_ops cannot index recursive descent. Consider indexed persisted or generated scalar columns for frequent filters.")
      keys = path.map { "?" }.join(", ")
      object_values = "WHEN jsonb_typeof(parent.value) = 'object' THEN jsonb_path_query_array(parent.value, '$.*')" if descendants
      # Arrays retain their path depth; only the requested object key advances it.
      sql = <<~SQL.squish
        WITH RECURSIVE tinkick_filter_json(value, depth) AS (
          SELECT #{column}, 0
          UNION ALL
          SELECT element.value,
            parent.depth + CASE WHEN parent.depth < #{path.length} AND jsonb_typeof(parent.value) = 'object' THEN 1 ELSE 0 END
          FROM tinkick_filter_json AS parent
          CROSS JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_typeof(parent.value) = 'array' THEN parent.value
              WHEN parent.depth < #{path.length} AND jsonb_typeof(parent.value) = 'object'
                THEN jsonb_build_array(parent.value -> (ARRAY[#{keys}]::text[])[parent.depth + 1])
              #{object_values}
              ELSE '[]'::jsonb END
          ) AS element(value)
          WHERE parent.depth < #{path.length} OR jsonb_typeof(parent.value) = 'array'
            #{"OR jsonb_typeof(parent.value) = 'object'" if descendants}
        )
        SELECT value FROM tinkick_filter_json
        WHERE depth = #{path.length} AND jsonb_typeof(value) <> 'array'
      SQL
      [sql, path]
    end

    def warn_json_scan(column)
      Tinkick.warn(@model, "Tinkick: this JSONB filter scans values in #{column}; ordinary GIN indexes cannot extract selective equality keys for range, pattern, or missing-value checks. Consider an indexed persisted or generated scalar column for frequent filters.")
    end

    def field_predicates(column, value, array_type: nil, enum_values: nil)
      element = array_type ? "tinkick_filter_element.value" : column
      case value
      when Range
        [element_predicate(column, range_predicate(element, value, enum_values: enum_values), array_type)]
      when Hash
        # @type var comparisons: Array[filter_predicate]
        comparisons = []
        filters = value.flat_map do |operator, operand|
          case operator
          when :in
            [equality(column, operand, array_type: array_type, enum_values: enum_values)]
          when :all
            raise ArgumentError, "all requires an array of values" unless operand.is_a?(Array)

            operand.map { |entry| equality(column, entry, array_type: array_type, enum_values: enum_values) }
          when :exists
            [existence(column, operand, array_type: array_type, enum_values: enum_values)]
          when :like, :ilike, :prefix, :regexp
            [element_predicate(column, text_predicate(element, operator, operand, enum_values: enum_values), array_type)]
          when :not, :_not
            [negate(equality(column, operand, array_type: array_type, enum_values: enum_values))]
          when :gt, :gte, :lt, :lte
            comparisons << comparison(element, operator, operand, enum_values: enum_values)
            []
          else
            raise ArgumentError, "Unknown where operator: #{operator.inspect}"
          end
        end
        filters << element_predicate(column, combine(comparisons, "AND"), array_type) unless comparisons.empty?
        filters
      else
        [equality(column, value, array_type: array_type, enum_values: enum_values)]
      end
    end

    def equality(column, value, array_type: nil, enum_values: nil)
      if value.is_a?(Regexp)
        element = array_type ? "tinkick_filter_element.value" : column
        return element_predicate(column, text_predicate(element, :regexp, value, enum_values: enum_values), array_type)
      end
      if value.is_a?(Array)
        return ["FALSE", []] if value.empty?

        combine(value.map { |entry| equality(column, entry, array_type: array_type, enum_values: enum_values) }, "OR")
      elsif value.nil?
        if enum_values
          recognized = enum_values.values.map { |stored| equality(column, stored) }
          recognized.empty? ? ["TRUE", []] : negate(combine(recognized, "OR"))
        elsif array_type
          negate(element_predicate(column, ["tinkick_filter_element.value IS NOT NULL", []], array_type))
        else
          ["#{column} IS NULL", []]
        end
      elsif enum_values
        label = scalar(value).as_json.to_s
        return ["FALSE", []] unless enum_values.key?(label)

        equality(column, enum_values.fetch(label))
      elsif array_type
        ["#{column} @> ARRAY[?]::#{array_type}", [scalar(value)]]
      else
        ["#{column} = ?", [scalar(value)]]
      end
    end

    def existence(column, value, array_type: nil, enum_values: nil)
      case value
      when TrueClass
        negate(equality(column, nil, array_type: array_type, enum_values: enum_values))
      when FalseClass
        equality(column, nil, array_type: array_type, enum_values: enum_values)
      else
        raise ArgumentError, "Passing a value other than true or false to exists is not supported"
      end
    end

    def element_predicate(column, predicate, array_type)
      return predicate unless array_type

      Tinkick.warn(@model, "Tinkick: this filter scans array elements for #{column}; ordinary GIN array indexes cannot accelerate range, pattern, or missing-value checks. Consider a persisted or generated scalar column with an appropriate index for frequent filters.")
      sql, binds = predicate
      ["EXISTS (SELECT 1 FROM unnest(#{column}) AS tinkick_filter_element(value) WHERE #{sql})", binds]
    end

    def text_predicate(column, operator, value, enum_values: nil)
      column = enum_label_expression(column, enum_values)
      if operator == :regexp
        if value.is_a?(Regexp)
          raise NotImplementedError, "Ruby Regexp filters are not supported by TIN; use regexp: with a PostgreSQL pattern string instead"
        end
        raise TypeError, "regexp requires a PostgreSQL pattern string" unless value.is_a?(String)

        Tinkick.warn(@model, "Tinkick: regular expression filters can scan column values outside TIN. Use selective search/where conditions and inspect EXPLAIN; an optional pg_trgm expression index may help suitable patterns.")
        return ["(#{column})::text ~ ?", [value]]
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

    def comparison(column, operator, value, enum_values: nil)
      sql_operator = { gt: ">", gte: ">=", lt: "<", lte: "<=" }.fetch(operator)
      column = enum_label_expression(column, enum_values)
      operand = scalar(value)
      operand = operand.as_json.to_s if enum_values
      ["#{column} #{sql_operator} ?", [operand]]
    end

    def range_predicate(column, range, enum_values: nil)
      # @type var comparisons: Array[filter_predicate]
      comparisons = []
      lower = range.begin
      upper = range.end
      comparisons << comparison(column, :gte, lower, enum_values: enum_values) if lower && lower != -Float::INFINITY
      comparisons << comparison(column, range.exclude_end? ? :lt : :lte, upper, enum_values: enum_values) if upper && upper != Float::INFINITY
      combine(comparisons, "AND")
    end

    def enum_label_expression(column, enum_values)
      return column unless enum_values

      Tinkick.warn(@model, "Tinkick: filtering enum labels with ranges or patterns evaluates a CASE expression per row; an ordinary backing-column index cannot accelerate this expression. Use selective search/where conditions and inspect EXPLAIN, or add an appropriate expression index.")
      @model.with_connection do |connection|
        branches = enum_values.map do |label, stored|
          "WHEN #{column} IS NOT DISTINCT FROM #{connection.quote(stored)} THEN #{connection.quote(label)}::text"
        end
        "(CASE #{branches.join(" ")} ELSE NULL::text END) COLLATE \"C\""
      end
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
