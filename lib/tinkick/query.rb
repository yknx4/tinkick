# frozen_string_literal: true

require_relative "filter"
require_relative "query_text"
require_relative "text_match"
require_relative "keyset"
require_relative "search_field"
require_relative "aggregations"
require_relative "boost_by"
require_relative "conversion_scores"
require "active_support/notifications"

module Tinkick
  class Query
    attr_reader :model, :limit, :after, :took

    def initialize(model, term, base_scope: model.all, fields:, where: {}, order: nil, limit: 10_000, offset: nil, operator: "and", match: :word, misspellings: false, countless: false, keyset: false, after: nil, aggs: nil, smart_aggs: true, exclude: nil, boost_by: nil, boost_where: nil, boost: nil, boost_by_recency: nil, conversions: nil, conversions_v2: nil, conversions_term: nil)
      raise ArgumentError, "fields must contain at least one column" if fields.empty?

      @model = model
      @base_scope = base_scope.spawn
      @boost_by = BoostBy.new(model, boost_by, boost_where: boost_where, boost: boost, boost_by_recency: boost_by_recency)
      @term = term.to_s
      @conversions = normalize_conversions(conversions, conversions_v2, conversions_term)
      @fields = model.tinkick_expand_fields(fields, match: match).map do |field|
        if field.is_a?(Hash)
          raise ArgumentError, "Each field hash must contain one field and match mode" unless field.length == 1

          name, mode = field.to_a.fetch(0)
          parts = name.to_s.split("^", 2)
          [parts.fetch(0), mode, parts[1]&.to_f]
        else
          parts = field.to_s.split("^", 2)
          [parts.fetch(0), match, parts[1]&.to_f]
        end
      end
      @weighted_scoring = @fields.any? do |_name, mode, boost|
        boost && (boost > 10_000 || [:exact, :text_start, :text_middle, :text_end].include?(mode))
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

    def to_relation
      record_scope.limit(@limit)
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
      instrument(:search) do
        fields = columns.map { |field| field.to_s }
        projection = fields.map { |field| Arel.sql(quoted_column(field)) }
        relation = record_scope.reselect(*projection, Arel.sql("#{score_sql} AS _tinkick_score"))
        values = read_rows(relation)
        values = values.first(@limit) if countless?
        values.map { |row| row.slice(*fields) }
      end
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
      @total_count ||= instrument(:count) { scope.except(:order, :limit, :offset).count }
    end

    def misspellings?
      resolve_misspellings
      @misspellings != false && !(@term == "*" && @exclude.empty?)
    end

    def aggs
      spec = @aggregation_spec
      return unless spec
      return @aggs if @aggs

      @aggs = instrument(:aggregations) do
        resolve_misspellings
        specifications = if spec.is_a?(Array)
          spec.to_h do |field|
            empty_options = {} #: aggregation_options
            [field, empty_options]
          end
        else
          spec
        end
        base = build_scope({})
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
        output
      end
    end

    def highlight_fields
      @fields.map(&:first).uniq
    end

    def highlight_matches(name, texts:)
      resolve_misspellings
      matched = Array.new(texts.length) #: Array[String?]
      return matched if @term == "*"

      @fields.each do |field_name, mode|
        next unless name == field_name && [:exact, :text_start, :text_middle, :text_end].include?(mode)

        values = TextMatch.new(@model).highlight_matches(texts, @term, match: mode, misspellings: misspellings_for(name))
        values.each_with_index { |value, index| matched[index] ||= value }
      end
      matched
    end

    def highlight_query(name)
      resolve_misspellings
      return "" if @term == "*"

      @model.with_connection do |connection|
        compiler = QueryText.new(connection)
        @fields.filter_map do |field_name, mode|
          next unless field_name == name
          next unless [:word, :phrase, :word_start, :word_middle, :word_end].include?(mode)
          field = SearchField.new(@model, name, match: mode)
          analysis = @model.tinkick_index_analysis(name, field)
          unless analysis == QueryText::ANALYSIS_DEFAULTS
            raise NotImplementedError, "Native TIN highlighting for #{name.inspect} does not support non-default index tokenization: implicit highlighting rejects this configuration and explicit highlighting uses default analysis. Omit highlighting for this field or select a default-analysis field."
          end
          misspellings = misspellings_for(name)
          compiler.compile(@term, operator: @operator, match: mode, misspellings: misspellings, analysis: analysis)
        end.reject(&:empty?).map { |query| "(#{query})" }.join(" OR ")
      end
    end

    private

    def normalize_conversions(legacy, modern, term)
      return [] if @term == "*"

      declaration = @model.tinkick_options
      legacy_fields = declaration ? declaration[:conversions] : [] #: Array[String]
      modern_fields = declaration ? declaration[:conversions_v2] : [] #: Array[String]
      case_sensitive = declaration && declaration[:case_sensitive] == true
      term = (term || @term).to_s

      fields = legacy.nil? ? legacy_fields : (legacy ? Array(legacy) : []) #: Array[String | Symbol]
      unless fields.all? { |field| field.is_a?(String) || field.is_a?(Symbol) }
        raise ArgumentError, "conversions must name JSONB columns with a string, symbol, or array; false disables it"
      end
      scores = [ConversionScores.new(@model, fields: fields.map(&:to_s).uniq, term: term, case_sensitive: !!case_sensitive)]
      modern = legacy_fields.empty? if modern.nil?
      return scores if modern == false

      options = case modern
      when true then {}
      when String, Symbol then { field: modern }
      when Hash then modern
      else raise ArgumentError, "conversions_v2 must be true, false, a field name, or an options hash"
      end #: conversion_options
      unknown = options.keys - [:field, :term, :factor]
      raise ArgumentError, "Unknown conversions_v2 options: #{unknown.join(', ')}" unless unknown.empty?

      field = options[:field]
      selected = if field.nil? || field == true
        modern_fields
      elsif field.is_a?(String) || field.is_a?(Symbol)
        [field.to_s]
      else
        raise ArgumentError, "conversions_v2 field must be a column name, true, or nil"
      end
      selected_term = (options[:term] || term).to_s

      scores << ConversionScores.new(@model, fields: selected, term: selected_term,
        factor: options[:factor] || 1, case_sensitive: !!case_sensitive)
    end

    def measure_page
      instrument(:search) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value = yield
        @took ||= ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
        value
      end
    end

    def instrument(operation)
      ActiveSupport::Notifications.instrument("#{operation}.tinkick", name: "#{@model.name} #{operation.capitalize}", model: @model.name) { yield }
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
      selectors = fields.map { |field| (field.is_a?(Hash) ? field.keys.first.to_s : field.to_s).split("^", 2).fetch(0) }
      unless (selected - selectors).empty?
        raise ArgumentError, "All fields in per-field misspellings must also be specified in fields option"
      end
      selected_fields = fields.select do |field|
        selected.include?((field.is_a?(Hash) ? field.keys.first.to_s : field.to_s).split("^", 2).fetch(0))
      end
      @misspelling_fields = @model.tinkick_expand_fields(selected_fields, match: @match).map do |field|
        (field.is_a?(Hash) ? field.keys.first.to_s : field.to_s).split("^", 2).fetch(0)
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

      original = [@misspellings, @scoring, @mixed_matching] #: [QueryText::misspellings, String, bool]
      @misspellings = false
      begin
        Tinkick.warn(@model, "Tinkick: misspellings: { below: #{threshold} } runs an extra bounded exact-match count before choosing the search mode. Omit below to use the native fuzzy search directly.")
        exact = build_scope(@where)
        if exact.except(:order, :limit, :offset).limit(threshold).count < threshold
          @misspellings, @scoring, @mixed_matching = original
        else
          @scope = exact
        end
        @misspellings_below = nil
      rescue StandardError
        @misspellings, @scoring, @mixed_matching = original
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
        fields = @fields.map { |name, mode, boost| [name, SearchField.new(@model, name, match: mode), mode, boost] } #: Array[[String, SearchField, Symbol, Float?]]

        relation = Filter.new(@model).apply(@base_scope, conditions)
        compiler = QueryText.new(connection)
        relation, excluded = excluding_scope(relation, fields, compiler)
        next relation if @term == "*"

        native = [] #: Array[filter_predicate]
        exact = [] #: Array[filter_predicate]
        scored = [] #: Array[[Array[filter_predicate], String]]
        fields.each do |name, field, mode, boost|
          misspellings = misspellings_for(name)
          if [:exact, :text_start, :text_middle, :text_end].include?(mode)
            predicate = if mode == :exact
              field_predicate(field, ["#{field.text_sql}::text COLLATE \"C\" = ?", [@term]])
            else
              field_predicate(field, TextMatch.new(@model).predicate(field.text_sql, @term, match: mode, misspellings: misspellings))
            end
            exact << predicate
            score = "#{boost || 1.0}::double precision"
          else
            analysis = @model.tinkick_index_analysis(name, field)
            native_boost = boost && boost > 10_000 ? 1.0 : boost
            compiled = compiler.compile(@term, operator: @operator, match: mode, misspellings: misspellings, analysis: analysis)
            next if compiled.empty?

            compiled = "(#{compiled})^#{native_boost}" if native_boost
            compiled = "(#{compiled}) AND NOT (#{excluded})" if excluded
            predicate = field_predicate(field, ["#{field.text_sql} ==> ?", [compiled]])
            native << predicate
            score = "tin.full_score(#{quoted_table}.ctid)"
            score = "#{score}::double precision * #{boost}" if boost && boost > 10_000
          end
          scored << [[predicate], score] if @weighted_scoring
        end
        if @weighted_scoring
          scored_scope(relation, scored)
        elsif native.empty?
          matching_scope(relation, exact)
        elsif exact.empty?
          @scoring = "tin.score(#{quoted_table}.ctid)"
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

        analysis = @model.tinkick_index_analysis(name, field)
        phrases = @exclude.map do |phrase|
          compiler.exclusion(phrase, words: compiler.tokens(phrase, analysis: analysis), match: mode)
        end.reject(&:empty?)
        next if phrases.empty?

        excluded = phrases.map { |phrase| "(#{phrase})" }.join(" OR ")
        if fields.length == 1 && @term != "*"
          combined = excluded
          next
        end

        primary_key = @model.primary_key
        raise InvalidQueryError, "#{@model.name} requires a single primary key for exclusions" unless primary_key.is_a?(String)

        sql, binds = field_predicate(field, ["#{field.text_sql} ==> ?", [excluded]])
        identifiers = base.where(Arel.sql(sql, *binds)).select(primary_key)
        relation = relation.where.not(primary_key => identifiers)
        Tinkick.warn(@model, "Tinkick: phrase exclusions across fields or match-all searches use TIN matching-ID subqueries to preserve null values. These extra index queries can increase cost; inspect EXPLAIN ANALYZE for your workload.")
      end
      [relation, combined]
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
      scored_scope(relation, [[native, "tin.full_score(#{quoted_table}.ctid)"], [exact, "1.0"]])
    end

    def scored_scope(relation, scores)
      return relation.none if scores.empty?

      primary_key = @model.primary_key
      raise InvalidQueryError, "#{@model.name} requires a single primary key for search pagination" unless primary_key.is_a?(String)

      identifier = quoted_column(primary_key)
      projection = Arel.sql("#{identifier} AS _tinkick_id")
      branches = scores.map do |predicates, score|
        matching_scope(relation, predicates).reselect(projection, Arel.sql("#{score} AS _tinkick_branch_score"))
          .except(:order, :limit, :offset)
      end
      @scoring = "_tinkick_ranked.score"
      @mixed_matching = true
      @base_scope.with(_tinkick_matches: branches).joins(<<~SQL)
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
      if @weighted_scoring && @mixed_matching
        Tinkick.warn(@model, "Tinkick: weighted SQL scoring combines field queries, then can group and sort matching rows. Explicit SQL field weights and native field boosts above 10000 require this path; native-only field boosts up to 10000 keep TIN scoring. Inspect EXPLAIN ANALYZE for your workload.")
      elsif @mixed_matching
        Tinkick.warn(@model, "Tinkick: mixed TIN and SQL match modes combine and group matching rows before sorting. This can be slower than native TIN top-k ranking; use a single native match mode where its semantics fit and check EXPLAIN ANALYZE for your workload.")
      end
      if @offset.positive? && score != "1.0"
        Tinkick.warn(@model, "Tinkick: offset pagination can bypass TIN's native top-k path and sort matching rows. Consider keyset pagination on stable indexed columns to avoid large offsets. Countless pagination avoids automatic counts but does not remove offset costs.")
      end
      if @fields.length > 1 && score != "1.0" && !@mixed_matching
        Tinkick.warn(@model, "Tinkick: ranking across multiple fields combines TIN indexes and can require an additional sort. Inspect EXPLAIN ANALYZE for your workload. Consider a stored or generated combined text column with one TIN index when ranking performance matters.")
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
        Tinkick.warn(@model, "Tinkick: lexical search with column order or ascending relevance can sort matching rows instead of using TIN's relevance top-k path. Use stable indexed columns for keyset pagination and check the query plan for your workload.")
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
      score = @conversions.reduce(@scoring) { |base, conversions| conversions.score_sql(base) }
      @boost_by.score_sql(score)
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
