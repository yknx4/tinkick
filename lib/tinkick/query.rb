# frozen_string_literal: true

require_relative "filter"
require_relative "query_text"
require_relative "text_match"
require_relative "keyset"

module Tinkick
  class Query
    attr_reader :model, :limit, :after

    def initialize(model, term, fields:, where: {}, order: nil, limit: 10_000, offset: nil, operator: "and", match: :word, misspellings: false, countless: false, keyset: false, after: nil)
      raise ArgumentError, "fields must contain at least one column" if fields.empty?

      @model = model
      @term = term.to_s
      @fields = fields.map do |field|
        if field.is_a?(Hash)
          raise ArgumentError, "Each field hash must contain one field and match mode" unless field.length == 1

          name, mode = field.to_a.fetch(0)
          [name.to_s, mode]
        else
          [field.to_s, match]
        end
      end
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
      @scoring = "1.0"
      @mixed_matching = false
      @fuzzy_partial = false
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(@operator)
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
        @fields.each do |field, mode|
          column = @model.columns_hash[field]
          validate_column(field)
          sql_match = [:exact, :text_start, :text_middle, :text_end].include?(mode)
          text_types = sql_match ? [:text, :citext, :string] : [:text, :citext]
          array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
          unless column && !array && text_types.include?(column.type)
            raise InvalidQueryError, "#{@model.name}.#{field} must be a text or citext column with a TIN index"
          end
        end

        relation = Filter.new(@model).apply(@model.all, @where)
        next relation if @term == "*"

        native = [] #: Array[filter_predicate]
        exact = [] #: Array[filter_predicate]
        compiler = QueryText.new(connection)
        @fields.each do |field, mode|
          if mode == :exact
            exact << ["#{quoted_column(field)}::text COLLATE \"C\" = ?", [@term]]
          elsif [:text_start, :text_middle, :text_end].include?(mode)
            exact << TextMatch.new(@model).predicate(quoted_column(field), @term, match: mode, misspellings: @misspellings)
          else
            compiled = compiler.compile(@term, operator: @operator, match: mode, misspellings: @misspellings)
            if [:word_start, :word_middle, :word_end].include?(mode) && @misspellings != false && compiled.include?("MATCHES")
              @fuzzy_partial = true
            end
            native << ["#{quoted_column(field)} ==> ?", [compiled]] unless compiled.empty?
          end
        end
        if native.empty?
          matching_scope(relation, exact)
        elsif exact.empty?
          @scoring = native.length > 1 ? "tin.full_score(#{quoted_table}.ctid)" : "tin.score(#{quoted_table}.ctid)"
          matching_scope(relation, native)
        else
          mixed_scope(relation, native, exact)
        end
      end
    end

    def matching_scope(relation, predicates)
      return relation.none if predicates.empty?

      sql = predicates.map { |predicate, _binds| "(#{predicate})" }.join(" OR ")
      binds = predicates.flat_map { |_predicate, values| values }
      relation.where(Arel.sql("(#{sql})", *binds))
    end

    def mixed_scope(relation, native, exact)
      primary_key = @model.primary_key
      raise InvalidQueryError, "#{@model.name} requires a single primary key for search pagination" unless primary_key.is_a?(String)

      identifier = quoted_column(primary_key)
      projection = Arel.sql("#{identifier} AS _tinkick_id")
      branches = [
        matching_scope(relation, native).reselect(projection, Arel.sql("tin.full_score(#{quoted_table}.ctid) AS _tinkick_branch_score")),
        matching_scope(relation, exact).reselect(projection, Arel.sql("1.0 AS _tinkick_branch_score")),
      ].map { |branch| branch.except(:order, :limit, :offset) }
      @scoring = "_tinkick_ranked.score"
      @mixed_matching = true
      @model.all.with(_tinkick_matches: branches).joins(<<~SQL)
        INNER JOIN (
          SELECT _tinkick_id, SUM(_tinkick_branch_score) AS score
          FROM _tinkick_matches GROUP BY _tinkick_id
        ) AS _tinkick_ranked ON _tinkick_ranked._tinkick_id = #{identifier}
      SQL
    end

    def record_scope
      relation = scope
      primary_key = @model.primary_key
      raise InvalidQueryError, "#{@model.name} requires a single primary key for search pagination" unless primary_key.is_a?(String)

      score = score_sql
      if @fuzzy_partial
        @model.logger&.warn("Tinkick: Fuzzy partial matching expands patterns in TIN's token dictionary. Broad prefixes or infixes can increase query cost; use misspellings: false when typo matching is unnecessary and inspect EXPLAIN ANALYZE with representative data.")
      end
      if @mixed_matching
        @model.logger&.warn("Tinkick: mixed TIN and SQL match modes combine and group matching rows before sorting. This can be slower than native TIN top-k ranking; use a single native match mode where its semantics fit and check EXPLAIN ANALYZE for your workload.")
      end
      if @offset.positive? && score != "1.0"
        @model.logger&.warn("Tinkick: offset pagination can bypass TIN's native top-k path and sort matching rows. Consider keyset pagination on stable indexed columns to avoid large offsets. Countless pagination avoids automatic counts but does not remove offset costs.")
      end
      if @fields.length > 1 && score != "1.0" && !@mixed_matching
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
      @scoring
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
