# frozen_string_literal: true

require_relative "filter"
require_relative "query_text"
require_relative "text_match"
require_relative "keyset"
require_relative "search_field"
require_relative "word_match"
require_relative "aggregations"

module Tinkick
  class Query
    attr_reader :model, :limit, :after, :took

    def initialize(model, term, fields:, where: {}, order: nil, limit: 10_000, offset: nil, operator: "and", match: :word, misspellings: false, countless: false, keyset: false, after: nil, aggs: nil, smart_aggs: true, exclude: nil)
      raise ArgumentError, "fields must contain at least one column" if fields.empty?

      @model = model
      @term = term.to_s
      @fields = model.tinkick_expand_fields(fields, match: match).map do |field|
        if field.is_a?(Hash)
          raise ArgumentError, "Each field hash must contain one field and match mode" unless field.length == 1

          name, mode = field.to_a.fetch(0)
          [name.to_s, mode]
        else
          [field.to_s, match]
        end
      end
      @where = where
      @aggregation_spec = aggs
      @smart_aggs = smart_aggs
      @order = order
      @limit = limit.to_i
      @offset = offset.to_i
      @operator = operator.to_s
      @match = match
      @misspelling_fields = nil
      @misspellings_below = nil
      @misspellings = normalize_misspellings(misspellings, fields)
      @exclude = normalize_exclusions(exclude)
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
      @records ||= measure_page { trim_page(record_scope.to_a) }
    end

    def rows
      @rows ||= measure_page { trim_page(read_rows(record_scope)) }
    end

    def source_rows(columns)
      measure_page do
        primary_key = @model.primary_key
        unless primary_key.is_a?(String)
          raise InvalidQueryError, "source projection requires a single model primary key"
        end
        fields = columns | [primary_key]
        cursor_fields = keyset? ? keyset_order.columns : [] #: Array[String]
        projection = (fields | cursor_fields).map { |field| Arel.sql(quoted_column(field)) }
        relation = record_scope.reselect(*projection, Arel.sql("#{score_sql} AS _tinkick_score"))
        values = trim_page(read_rows(relation))
        @source_cursor_row = values.last
        values.map { |row| row.slice(*fields, "_tinkick_score") }
      end
    end

    def pluck_rows(columns)
      fields = columns.map { |field| field.to_s }
      projection = fields.map { |field| Arel.sql(quoted_column(field)) }
      relation = record_scope.reselect(*projection, Arel.sql("#{score_sql} AS _tinkick_score"))
      values = read_rows(relation)
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

      row = @source_cursor_row || @rows&.last || @records&.last&.attributes
      row ? keyset_order.encode(row) : nil
    end

    def total_count
      @total_count ||= scope.except(:order, :limit, :offset).count
    end

    def misspellings?
      resolve_misspellings
      @misspellings != false && !(@term == "*" && @exclude.empty?)
    end

    def aggs
      spec = @aggregation_spec
      return unless spec
      return @aggs if @aggs

      resolve_misspellings
      specifications = if spec.is_a?(Array)
        spec.to_h do |field|
          empty_options = {} #: aggregation_options
          [field, empty_options]
        end
      else
        spec
      end
      base = build_scope(@smart_aggs ? {} : @where)
      output = {} #: Hash[String, aggregation_result]
      specifications.each do |name, options|
        conditions = options[:where] || {}
        if @smart_aggs
          other_filters = @where.reject { |field, _value| field.to_s == name.to_s }
          unless other_filters.empty?
            conditions = conditions.empty? ? other_filters : @where.merge(conditions)
          end
        end
        aggregate_options = options.merge(where: conditions) #: aggregation_options
        output.merge!(Aggregations.new(@model, base).call({ name => aggregate_options }))
      end
      @aggs = output
    end

    private

    def measure_page
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      value = yield
      @took ||= ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
      value
    end

    def normalize_misspellings(options, fields)
      return options unless options.is_a?(Hash)

      normalized = options.dup
      below = normalized.delete(:below)
      if below
        unless below.is_a?(Integer) || below.is_a?(String) || (below.is_a?(Float) && below.finite?)
          raise ArgumentError, "misspellings below must be a finite number or numeric string"
        end
        @misspellings_below = below.to_i
      end
      return normalized unless normalized.key?(:fields)

      names = normalized.delete(:fields)
      unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) || name.is_a?(Symbol) }
        raise ArgumentError, "misspellings fields must be an array of field names"
      end
      selected = names.map(&:to_s)
      selectors = fields.map { |field| field.is_a?(Hash) ? field.keys.first.to_s : field.to_s }
      unless (selected - selectors).empty?
        raise ArgumentError, "All fields in per-field misspellings must also be specified in fields option"
      end
      selected_fields = fields.select do |field|
        selected.include?(field.is_a?(Hash) ? field.keys.first.to_s : field.to_s)
      end
      @misspelling_fields = @model.tinkick_expand_fields(selected_fields, match: @match).map do |field|
        field.is_a?(Hash) ? field.keys.first.to_s : field.to_s
      end
      normalized
    end

    def resolve_misspellings
      threshold = @misspellings_below
      return unless threshold
      return if @term == "*" && @exclude.empty?

      if threshold <= 0
        @misspellings = false
        @misspellings_below = nil
        return
      end

      original = [@misspellings, @scoring, @mixed_matching, @fuzzy_partial] #: [QueryText::misspellings, String, bool, bool]
      @misspellings = false
      begin
        @model.logger&.warn("Tinkick: misspellings: { below: #{threshold} } runs an extra bounded exact-match count before choosing the search mode. Omit below to use the native fuzzy search directly.")
        exact = build_scope(@where)
        if exact.except(:order, :limit, :offset).limit(threshold).count < threshold
          @misspellings, @scoring, @mixed_matching, @fuzzy_partial = original
        else
          @scope = exact
        end
        @misspellings_below = nil
      rescue StandardError
        @misspellings, @scoring, @mixed_matching, @fuzzy_partial = original
        raise
      end
    end

    def misspellings_for(name)
      fields = @misspelling_fields
      fields && !fields.include?(name) ? false : @misspellings
    end

    def normalize_exclusions(value)
      return [] if value.nil? || value == false

      values = value.is_a?(Array) ? value : [value]
      values.map do |phrase|
        valid = phrase.is_a?(String) || phrase.is_a?(Integer) || phrase == true || phrase == false ||
          (phrase.is_a?(Float) && phrase.finite?)
        unless valid
          raise ArgumentError, "exclude must contain scalar strings, finite numbers, or booleans"
        end

        phrase.to_s
      end
    end

    def read_rows(relation)
      values = @model.with_connection { |connection| connection.select_all(relation).to_a }
      values.map do |row|
        row.to_h do |field, value|
          # Raw query results still need the model's PostgreSQL array/JSON types.
          cast = field == "_tinkick_score" ? value : @model.type_for_attribute(field).deserialize(value) #: result_value
          [field, cast]
        end
      end
    end

    def trim_page(values)
      @has_next_page = countless? && values.length > @limit
      countless? ? values.first(@limit) : values
    end

    def keyset_order
      @keyset_order ||= Keyset.new(@model, @order)
    end

    def scope
      resolve_misspellings
      @scope ||= build_scope(@where)
    end

    def build_scope(conditions)
      @model.with_connection do |connection|
        fields = @fields.map { |name, mode| [name, SearchField.new(@model, name, match: mode), mode] } #: Array[[String, SearchField, Symbol]]

        relation = Filter.new(@model).apply(@model.all, conditions)
        compiler = QueryText.new(connection)
        relation, excluded = excluding_scope(relation, fields, compiler)
        next relation if @term == "*"

        native = [] #: Array[filter_predicate]
        exact = [] #: Array[filter_predicate]
        fields.each do |name, field, mode|
          misspellings = misspellings_for(name)
          if mode == :exact
            exact << field_predicate(field, ["#{field.text_sql}::text COLLATE \"C\" = ?", [@term]])
          elsif [:text_start, :text_middle, :text_end].include?(mode)
            exact << field_predicate(field, TextMatch.new(@model).predicate(field.text_sql, @term, match: mode, misspellings: misspellings))
          else
            analysis = @model.tinkick_index_analysis(name, field)
            if two_edit_word?(mode, misspellings) || (mode == :word && compiler.refinement_required?(@term, misspellings: misspellings, analysis: analysis))
              native << field_predicate(field, WordMatch.new(@model).predicate(name, @term, operator: @operator, match: mode, misspellings: misspellings, excluded: excluded))
            else
              compiled = compiler.compile(@term, operator: @operator, match: mode, misspellings: misspellings, analysis: analysis)
              compiled = "(#{compiled}) AND NOT (#{excluded})" if excluded && !compiled.empty?
              if [:word_start, :word_middle, :word_end].include?(mode) && misspellings != false && compiled.include?("MATCHES")
                @fuzzy_partial = true
              end
              native << field_predicate(field, ["#{field.text_sql} ==> ?", [compiled]]) unless compiled.empty?
            end
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

    def excluding_scope(relation, fields, compiler)
      return [relation, nil] if @exclude.empty?

      base = relation
      combined = nil #: String?
      fields.each do |name, field, mode|
        if [:exact, :text_start, :text_middle, :text_end].include?(mode)
          @exclude.each do |phrase|
            predicate = if mode == :exact
              ["#{field.text_sql}::text COLLATE \"C\" = ?", [phrase]] #: filter_predicate
            else
              TextMatch.new(@model).predicate(field.text_sql, phrase, match: mode, misspellings: false)
            end
            sql, binds = field_predicate(field, predicate)
            relation = relation.where(Arel.sql("(#{sql}) IS NOT TRUE", *binds))
          end
          next
        end

        analysis = WordMatch.new(@model).index_analysis(name, field)
        phrases = @exclude.map do |phrase|
          compiler.exclusion(phrase, words: compiler.tokens(phrase, analysis: analysis), match: mode)
        end.reject(&:empty?)
        next if phrases.empty?

        excluded = phrases.map { |phrase| "(#{phrase})" }.join(" OR ")
        if fields.length == 1 && @term != "*" && !two_edit_word?(mode, misspellings_for(name))
          combined = excluded
          next
        end

        primary_key = @model.primary_key
        raise InvalidQueryError, "#{@model.name} requires a single primary key for exclusions" unless primary_key.is_a?(String)

        sql, binds = field_predicate(field, ["#{field.text_sql} ==> ?", [excluded]])
        identifiers = base.where(Arel.sql(sql, *binds)).select(primary_key)
        relation = relation.where.not(primary_key => identifiers)
        @model.logger&.warn("Tinkick: phrase exclusions across fields, match-all searches, or refined fuzzy modes use TIN matching-ID subqueries to preserve null values. These extra index queries can increase cost; inspect EXPLAIN ANALYZE for your workload.")
      end
      [relation, combined]
    end

    def two_edit_word?(mode, options)
      return false unless options.is_a?(Hash)

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      supported = [:word_start, :word_middle, :word_end].include?(mode) ||
        (mode == :word && options.fetch(:transpositions, true) == true)
      supported && distance.is_a?(Integer) && distance == 2
    end

    def field_predicate(field, predicate)
      scalar = field.scalar_predicate
      sql, binds = predicate
      [scalar ? "(#{scalar}) AND (#{sql})" : sql, binds]
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
      order = @order
      ordering = if keyset?
        after = @after
        relation = keyset_order.apply(relation, after) if after
        [keyset_order.order_sql]
      else
        order.nil? ? ["_tinkick_score DESC"] : order_clauses(order)
      end
      if ordering != ["_tinkick_score DESC"] && score != "1.0"
        @model.logger&.warn("Tinkick: lexical search with column order or ascending relevance can sort matching rows instead of using TIN's relevance top-k path. Use stable indexed columns for keyset pagination and check the query plan for your workload.")
      end

      relation.reselect(Arel.sql("#{quoted_table}.*"), Arel.sql("#{score} AS _tinkick_score"))
        .reorder(Arel.sql(ordering.join(", ")))
        .limit(countless? ? @limit + 1 : @limit).offset(@offset.zero? ? nil : @offset)
    end

    def order_clauses(value, array: false)
      case value
      when Array
        value.flat_map { |entry| order_clauses(entry, array: true) }
      when Hash
        value.map do |field, direction|
          direction = direction.to_s.downcase
          raise ArgumentError, "order direction must be asc or desc" unless ["asc", "desc"].include?(direction)

          "#{order_expression(field.to_s)} #{direction.upcase}"
        end
      else
        # Searchkick turns a scalar order into an explicit ascending sort;
        # bare _score entries in sort arrays inherit Elasticsearch's descending default.
        direction = array && value.to_s == "_score" ? "DESC" : "ASC"
        ["#{order_expression(value.to_s)} #{direction}"]
      end
    end

    def order_expression(field)
      field == "_score" ? "_tinkick_score" : quoted_column(field)
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
