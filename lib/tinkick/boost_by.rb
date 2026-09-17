# frozen_string_literal: true

require_relative "filter"
require_relative "recency_boost"

module Tinkick
  class BoostBy
    MAX_SCORE = 3.4028234663852886e38

    def initialize(model, specification, boost_where: nil, boost: nil, boost_by_recency: nil)
      @model = model
      @sums = [] #: Array[[String, String]]
      @multipliers = [] #: Array[[String, String]]
      @warned = false
      @numeric_scoring = false
      @recency_spec = boost_by_recency
      @now = Time.now
      unless !boost_by_recency || boost_by_recency.is_a?(Hash)
        raise ArgumentError, "boost_by_recency must be a field options hash"
      end
      @conditions = conditional_functions(boost_where)
      @conditional_scoring = @conditions.any? { |_condition, weight| weight.positive? }
      return unless specification || boost

      fields = if specification.is_a?(Array)
        specification.to_h { |field| [field, {}] }
      else
        specification || {}
      end #: Hash[String | Symbol, numeric_boost_options]
      raise ArgumentError, "boost_by must be an array of numeric fields or a field options hash" unless fields.is_a?(Hash)

      entries = fields.to_a
      if boost
        # The legacy alias replaces a sum function, but retains a multiply function.
        entries.reject! { |name, options| name == boost && options[:boost_mode] != "multiply" }
        entries << [boost, { factor: 1 }]
      end
      entries.each do |name, options|
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
      @numeric_scoring = !entries.empty?
    end

    def empty?
      recency = @recency_spec
      @sums.empty? && @multipliers.empty? && @conditions.empty? && (!recency || recency.empty?)
    end

    def score_sql(base_score)
      compile_recency if @recency_spec
      compile_conditions unless @conditions.empty?
      return base_score if empty?

      if !@warned && (@numeric_scoring || @conditional_scoring)
        message = if @conditional_scoring
          "Tinkick: conditional boost_where scoring evaluates filters for matching rows and can sort results instead of using native TIN top-k. Inspect EXPLAIN ANALYZE with representative data before using this on large result sets."
        else
          "Tinkick: numeric boost_by scoring evaluates numeric fields for matching rows and can sort results instead of using native TIN top-k. Numeric arrays and JSONB paths also inspect values per row. Inspect EXPLAIN ANALYZE with representative data before using this on large result sets."
        end
        @model.logger&.warn(message)
        @warned = true
      end
      "((#{base_score})::double precision * #{group(@sums, '+')} * #{group(@multipliers, '*')})"
    end

    private

    def compile_recency
      compiler = RecencyBoost.new(@model, @recency_spec, now: @now)
      functions = compiler.functions
      single = @sums.length + @conditions.length + functions.length == 1
      functions.each_with_index do |function, index|
        # A lone unfiltered function uses FIRST upstream; a SUM group whose
        # matched weights are all zero retains the identity instead.
        next if !single && compiler.weights.fetch(index).zero?

        @sums << function
      end
      @recency_spec = nil
    end

    def conditional_functions(specification)
      return [] unless specification
      raise ArgumentError, "boost_where must be a field conditions hash" unless specification.is_a?(Hash)

      specification.flat_map do |field, value|
        descriptors = if value.is_a?(Array) && value.first.is_a?(Hash)
          unless value.all? { |entry| entry.is_a?(Hash) }
            raise ArgumentError, "boost_where descriptor arrays must contain value/factor hashes"
          end
          value
        else
          [value]
        end
        descriptors.map do |descriptor|
          if descriptor.is_a?(Hash)
            [{ field => descriptor[:value] }, conditional_number(descriptor[:factor])]
          else
            [{ field => descriptor }, 1000.0]
          end
        end
      end
    end

    def conditional_number(value)
      unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal) || value.is_a?(String)
        raise ArgumentError, "boost_where factor must be a nonnegative number or numeric string"
      end
      result = if value.is_a?(String) && ["Infinity", "+Infinity"].include?(value.strip)
        Float::INFINITY
      else
        Float(value)
      end
      if result.nan? || result.negative? || (result.zero? && (1.0 / result).negative?)
        raise ArgumentError, "boost_where factor must be a nonnegative number or numeric string"
      end

      [result, MAX_SCORE].min
    rescue ArgumentError, TypeError
      raise ArgumentError, "boost_where factor must be a nonnegative number or numeric string"
    end

    def compile_conditions
      filter = Filter.new(@model)
      # @type var functions: Array[[String, String]]
      functions = @conditions.filter_map do |conditions, weight|
        sql, binds = filter.predicate(conditions)
        # Elasticsearch's sum group keeps its identity when only zero weights match.
        next if weight.zero?

        quoted = binds.empty? ? sql : @model.sanitize_sql_array([sql, *binds])
        [quoted, weight.to_s]
      end
      @sums.concat(functions)
      @conditions.clear
    end

    def number(value)
      unless value.nil? || value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal) || value.is_a?(String)
        raise ArgumentError, "boost_by factor and missing values must be finite numbers or numeric strings"
      end
      result = value.to_f
      raise ArgumentError, "boost_by factor and missing values must be finite" unless result.finite?

      result
    end

    def numeric_field(name)
      path = name.split(".", -1)
      root = path.shift.to_s
      column = @model.columns_hash[root]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{root.inspect}; add a numeric column with a Rails migration before using boost_by"
      end
      array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
      unless path.empty?
        unless column.type == :jsonb && !array
          raise InvalidQueryError, "#{@model.name}.#{root} must be a nonarray JSONB column for dotted boost_by paths"
        end
        if path.any? { |key| key.empty? || key.include?("\0") }
          raise ArgumentError, "JSON boost_by paths require nonempty keys without null bytes"
        end

        return json_numeric_field(root, path)
      end
      unless [:integer, :float, :decimal].include?(column.type)
        raise ArgumentError, "boost_by field #{name.inspect} must be a numeric PostgreSQL column or numeric array"
      end

      @model.with_connection do |connection|
        field = "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
        if array
          field = "(SELECT MIN(tinkick_boost_value) FROM unnest(#{field}) AS tinkick_boost_values(tinkick_boost_value))"
        end
        "(#{field})::numeric"
      end
    end

    def json_numeric_field(root, path)
      @model.with_connection do |connection|
        field = "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(root)}"
        keys = path.map { |key| connection.quote(key) }.join(", ")
        value = "NULLIF(value #>> '{}', '')::double precision"
        # Arrays retain their path depth; objects advance through only the requested key.
        <<~SQL.squish
          (WITH RECURSIVE tinkick_boost_json(value, depth) AS (
            SELECT #{field}, 0
            UNION ALL
            SELECT element.value,
              parent.depth + CASE WHEN jsonb_typeof(parent.value) = 'array' THEN 0 ELSE 1 END
            FROM tinkick_boost_json AS parent
            CROSS JOIN LATERAL jsonb_array_elements(
              CASE WHEN jsonb_typeof(parent.value) = 'array' THEN parent.value
                WHEN parent.depth < #{path.length} AND jsonb_typeof(parent.value) = 'object'
                  THEN jsonb_build_array(parent.value -> (ARRAY[#{keys}]::text[])[parent.depth + 1])
                ELSE '[]'::jsonb END
            ) AS element(value)
            WHERE parent.depth < #{path.length} OR jsonb_typeof(parent.value) = 'array'
          )
          SELECT MIN(CASE
            WHEN #{value} IS NULL THEN NULL
            WHEN #{value} > '-Infinity'::double precision AND #{value} < 'Infinity'::double precision
              THEN (#{value})::numeric
            ELSE ('boost_by JSONB value must be finite: ' || value::text)::numeric
          END)
          FROM tinkick_boost_json WHERE depth = #{path.length} AND jsonb_typeof(value) <> 'array')
        SQL
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
