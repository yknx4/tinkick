# frozen_string_literal: true

require_relative "filter"
require_relative "query_text"
require_relative "keyset"

module Tinkick
  class Query
    attr_reader :model, :limit, :after

    def initialize(model, term, fields:, where: {}, order: nil, limit: 10_000, offset: nil, operator: "and", match: :word, misspellings: false, countless: false, keyset: false, after: nil)
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
      @countless = countless || keyset
      @keyset = keyset
      @after = after
      raise ArgumentError, "limit and offset must be nonnegative" if @limit.negative? || @offset.negative?
      raise InvalidQueryError, "countless pagination requires a positive limit" if @countless && @limit.zero?
      raise InvalidQueryError, "keyset pagination does not accept offset; use after: with next_cursor" if keyset && !offset.nil?
      raise InvalidQueryError, "after must be an opaque cursor string" unless after.nil? || after.is_a?(String)
      raise InvalidQueryError, "after requires keyset: true" if after && !keyset
    end

    def records
      @records ||= trim_page(record_scope.to_a)
    end

    def rows
      @rows ||= trim_page(@model.with_connection { |connection| connection.select_all(record_scope).to_a })
    end

    def pluck_rows(columns)
      fields = columns.map { |field| field.to_s }
      projection = fields.map { |field| Arel.sql(quoted_column(field)) }
      relation = record_scope.reselect(*projection, Arel.sql("#{score_sql} AS _tinkick_score"))
      values = @model.with_connection { |connection| connection.select_all(relation).to_a }
      values = values.first(@limit) if countless?
      values.map { |row| row.slice(*fields) }
    end

    def countless?
      @countless
    end

    def keyset?
      @keyset
    end

    def has_next_page?
      records if @has_next_page.nil?
      @has_next_page == true
    end

    def next_cursor
      return unless keyset? && has_next_page?

      row = @rows&.last || @records&.last&.attributes
      row ? keyset_order.encode(row) : nil
    end

    def total_count
      @total_count ||= scope.except(:order, :limit, :offset).count
    end

    private

    def trim_page(values)
      @has_next_page = countless? && values.length > @limit
      countless? ? values.first(@limit) : values
    end

    def keyset_order
      @keyset_order ||= Keyset.new(@model, @order)
    end

    def scope
      @scope ||= @model.with_connection do |connection|
        @fields.each do |field|
          column = @model.columns_hash[field]
          validate_column(field)
          text_types = @match == :exact ? [:text, :citext, :string] : [:text, :citext]
          array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
          unless column && !array && text_types.include?(column.type)
            raise InvalidQueryError, "#{@model.name}.#{field} must be a text or citext column with a TIN index"
          end
        end

        compiled_query = if @match == :exact
          @term
        else
          QueryText.new(connection).compile(@term, operator: @operator, match: @match, misspellings: @misspellings)
        end
        @compiled_query = compiled_query
        relation = Filter.new(@model).apply(@model.all, @where)
        if compiled_query == "*"
          relation
        elsif @match == :exact
          predicates = @fields.map { |field| "#{quoted_column(field)}::text COLLATE \"C\" = ?" }.join(" OR ")
          relation.where(Arel.sql("(#{predicates})", *Array.new(@fields.length, @term)))
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

      score = score_sql
      if @offset.positive? && score != "1.0"
        @model.logger&.warn("Tinkick: offset pagination can bypass TIN's native top-k path and sort matching rows. Consider keyset pagination on stable indexed columns to avoid large offsets. Countless pagination avoids automatic counts but does not remove offset costs.")
      end
      if @fields.length > 1 && score != "1.0"
        @model.logger&.warn("Tinkick: ranking across multiple fields uses full scoring to preserve matching rows and can sort matches instead of using TIN's native top-k path. Consider a stored or generated combined text column with one TIN index when ranking performance matters.")
      end
      if (keyset? || !@order.nil?) && score != "1.0"
        @model.logger&.warn("Tinkick: lexical search with column order can sort matching rows instead of using TIN's relevance top-k path. Use stable indexed columns for keyset pagination and check the query plan for your workload.")
      end
      order = @order
      ordering = if keyset?
        after = @after
        relation = keyset_order.apply(relation, after) if after
        [keyset_order.order_sql]
      else
        order.nil? ? ["_tinkick_score DESC"] : order_clauses(order)
      end

      relation.reselect(Arel.sql("#{quoted_table}.*"), Arel.sql("#{score} AS _tinkick_score"))
        .reorder(Arel.sql(ordering.join(", ")))
        .limit(countless? ? @limit + 1 : @limit).offset(@offset.zero? ? nil : @offset)
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

    def score_sql
      # Native scoring permits dense-term elision and the index's top-k path.
      if @match == :exact || @compiled_query == "*" || @compiled_query == ""
        "1.0"
      elsif @fields.length > 1
        # Native dense-term elision can lose matches in TIN's multi-index plan.
        "tin.full_score(#{quoted_table}.ctid)"
      else
        "tin.score(#{quoted_table}.ctid)"
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
