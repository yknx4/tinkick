# frozen_string_literal: true

require_relative "filter"
require_relative "query_text"

module Tinkick
  class Query
    attr_reader :model, :limit

    def initialize(model, term, fields:, where: {}, order: nil, limit: 10_000, offset: 0, operator: "and", match: :word, misspellings: false)
      raise ArgumentError, "fields must contain at least one column" if fields.empty?

      @model = model
      @term = term.to_s
      @fields = fields.map(&:to_s)
      @where = where
      @order = order
      @limit = limit.to_i
      @offset = offset.to_i
      @operator = operator.to_s
      @match = match
      @misspellings = misspellings
      raise ArgumentError, "limit and offset must be nonnegative" if @limit.negative? || @offset.negative?
    end

    def records
      @records ||= record_scope.to_a
    end

    def rows
      @rows ||= @model.with_connection { |connection| connection.select_all(record_scope).to_a }
    end

    def total_count
      @total_count ||= scope.except(:order, :limit, :offset).count
    end

    private

    def scope
      @scope ||= @model.with_connection do |connection|
        @fields.each do |field|
          column = @model.columns_hash[field]
          validate_column(field)
          unless column && [:text, :citext].include?(column.type)
            raise InvalidQueryError, "#{@model.name}.#{field} must be a text or citext column with a TIN index"
          end
        end

        compiled_query = QueryText.new(connection).compile(@term, operator: @operator, match: @match, misspellings: @misspellings)
        @compiled_query = compiled_query
        relation = Filter.new(@model).apply(@model.all, @where)
        if compiled_query == "*"
          relation
        elsif compiled_query.empty?
          relation.none
        else
          predicates = @fields.map { |field| "#{quoted_column(field)} ==> ?" }.join(" OR ")
          relation.where(Arel.sql("(#{predicates})", *Array.new(@fields.length, compiled_query)))
        end
      end
    end

    def record_scope
      relation = scope
      primary_key = @model.primary_key
      raise InvalidQueryError, "#{@model.name} requires a single primary key for search pagination" unless primary_key.is_a?(String)

      # Native scoring permits dense-term elision and the index's top-k path.
      score = if @compiled_query == "*" || @compiled_query == ""
        "1.0"
      elsif @fields.length > 1
        # Native dense-term elision can lose matches in TIN's multi-index plan.
        "tin.full_score(#{quoted_table}.ctid)"
      else
        "tin.score(#{quoted_table}.ctid)"
      end
      if @offset.positive? && score != "1.0"
        @model.logger&.warn("Tinkick: offset pagination can bypass TIN's native top-k path and sort matching rows. Large offsets may be slow.")
      end
      if @fields.length > 1 && score != "1.0"
        @model.logger&.warn("Tinkick: ranking across multiple fields uses full scoring to preserve matching rows and can sort matches instead of using TIN's native top-k path. Consider a stored or generated combined text column with one TIN index when ranking performance matters.")
      end
      order = @order
      ordering = order.nil? ? ["_tinkick_score DESC"] : order_clauses(order)

      relation.reselect(Arel.sql("#{quoted_table}.*"), Arel.sql("#{score} AS _tinkick_score"))
        .reorder(Arel.sql(ordering.join(", ")))
        .limit(@limit).offset(@offset.zero? ? nil : @offset)
    end

    def order_clauses(value)
      case value
      when Array
        value.flat_map { |entry| order_clauses(entry) }
      when Hash
        value.map do |field, direction|
          direction = direction.to_s.downcase
          raise ArgumentError, "order direction must be asc or desc" unless ["asc", "desc"].include?(direction)

          "#{quoted_column(field.to_s)} #{direction.upcase}"
        end
      else
        ["#{quoted_column(value.to_s)} ASC"]
      end
    end

    def validate_column(field)
      return if @model.columns_hash.key?(field)

      raise MissingFieldError, "#{@model.name} has no column #{field.inspect}; add it with a Rails migration before searching"
    end

    def quoted_column(field)
      validate_column(field)
      @model.with_connection { |connection| "#{quoted_table}.#{connection.quote_column_name(field)}" }
    end

    def quoted_table
      @model.with_connection { |connection| connection.quote_table_name(@model.table_name) }
    end
  end
end
