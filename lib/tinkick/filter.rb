# frozen_string_literal: true

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
          field_predicates(quoted_column(field), value)
        end
      end
    end

    def quoted_column(field)
      name = field.to_s
      column = @model.columns_hash[name]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{name.inspect}; add it with a Rails migration before filtering"
      end
      array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
      if array || [:json, :jsonb].include?(column.type)
        raise InvalidQueryError, "Filtering #{name.inspect} requires array or JSON semantics that are not implemented yet"
      end

      @model.with_connection do |connection|
        "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
      end
    end

    def field_predicates(column, value)
      case value
      when Range
        [range_predicate(column, value)]
      when Hash
        # @type var comparisons: Array[filter_predicate]
        comparisons = []
        filters = value.flat_map do |operator, operand|
          case operator
          when :in
            [equality(column, operand)]
          when :all
            raise ArgumentError, "all requires an array of values" unless operand.is_a?(Array)

            operand.map { |entry| equality(column, entry) }
          when :exists
            [existence(column, operand)]
          when :like, :ilike, :prefix
            [text_predicate(column, operator, operand)]
          when :not, :_not
            [negate(equality(column, operand))]
          when :gt, :gte, :lt, :lte
            comparisons << comparison(column, operator, operand)
            []
          else
            raise ArgumentError, "Unknown where operator: #{operator.inspect}"
          end
        end
        filters << combine(comparisons, "AND") unless comparisons.empty?
        filters
      else
        [equality(column, value)]
      end
    end

    def equality(column, value)
      if value.is_a?(Array)
        return ["FALSE", []] if value.empty?

        combine(value.map { |entry| equality(column, entry) }, "OR")
      elsif value.nil?
        ["#{column} IS NULL", []]
      else
        ["#{column} = ?", [scalar(value)]]
      end
    end

    def existence(column, value)
      case value
      when TrueClass
        negate(equality(column, nil))
      when FalseClass
        equality(column, nil)
      else
        raise ArgumentError, "Passing a value other than true or false to exists is not supported"
      end
    end

    def text_predicate(column, operator, value)
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
