# frozen_string_literal: true

require_relative "relation"
require_relative "search_field"
require "json"

module Tinkick
  module Model
    def tinkick(searchable: nil, default_fields: nil, match: :word, stem: false,
      word_start: nil, word_middle: nil, word_end: nil, text_start: nil, text_middle: nil, text_end: nil, **options)
      # @type self: singleton(ActiveRecord::Base)
      raise ArgumentError, "stem must be true or false" unless stem == true || stem == false

      stemming = options.keys & [:language, :stemmer, :stem_exclusion, :stemmer_override]
      stemming.unshift(:stem) if stem
      unless stemming.empty?
        raise NotImplementedError, "Stemming (#{stemming.join(', ')}) is not yet supported by TIN. Use stem: false for native token matching, or add normalized stored columns with a Rails migration and normalize query text with the same rules"
      end
      raise ArgumentError, "unknown keywords: #{options.keys.join(', ')}" unless options.empty?
      raise ArgumentError, "Only call tinkick once per model" if tinkick_options

      [word_start, word_middle, word_end, text_start, text_middle, text_end].each do |fields|
        unless fields.nil? || (fields.is_a?(Array) && fields.all? { |field| field.is_a?(String) || field.is_a?(Symbol) })
          raise ArgumentError, "Partial match declarations must be arrays of field names"
        end
      end
      @tinkick_options = { searchable: searchable, default_fields: default_fields, match: match,
                          word_start: word_start, word_middle: word_middle, word_end: word_end,
                          text_start: text_start, text_middle: text_middle, text_end: text_end }
      singleton_class.alias_method(:search, :tinkick_search) unless respond_to?(:search, true)
    end

    def tinkick_options
      # @type self: singleton(ActiveRecord::Base)
      @tinkick_options || (superclass.respond_to?(:tinkick_options) ? superclass.public_send(:tinkick_options) : nil)
    end

    def tinkick_search(term = "*", fields: nil, misspellings: true, where: {}, order: nil, limit: nil, offset: nil, page: nil, per_page: nil, padding: nil, match: nil, operator: "and", load: true, total_entries: nil, countless: false, keyset: false, after: nil, aggs: nil, smart_aggs: true, includes: nil, model_includes: nil, scope_results: nil, exclude: nil, select: nil, highlight: nil)
      # @type self: singleton(ActiveRecord::Base)
      options = tinkick_options
      raise Error, "Declare tinkick on #{name} before calling tinkick_search" unless options
      raise Error, "search must be called on model, not relation" if current_scope

      schema = tinkick_schema
      fields ||= options[:default_fields] || options[:searchable] || tinkick_default_fields(schema)
      match ||= options[:match]
      selected = tinkick_expand_fields(fields, match: match)
      selected_names = selected.map { |field| field.is_a?(Hash) ? field.keys.first.to_s : field.to_s }
      declared = (options[:searchable] || []).reject { |field| selected_names.include?(field.to_s) }
      tinkick_validate_fields(schema, declared + selected, match)

      Relation.new(self, term, fields: fields, misspellings: misspellings,
        where: where, order: order, limit: limit, offset: offset, page: page,
        per_page: per_page, padding: padding, match: match,
        operator: operator, load: load, total_entries: total_entries,
        countless: countless, keyset: keyset, after: after, aggs: aggs, smart_aggs: smart_aggs, includes: includes, model_includes: model_includes, scope_results: scope_results, exclude: exclude, select: select, highlight: highlight)
    end

    def tinkick_expand_fields(fields, match:)
      # @type self: singleton(ActiveRecord::Base)
      fields.flat_map do |entry|
        if entry.is_a?(Hash)
          raise ArgumentError, "Each field hash must contain one field and match mode" unless entry.length == 1

          name, mode = entry.to_a.fetch(0)
        else
          name = entry
          mode = match
        end
        name = name.to_s
        next [entry] if mode == :exact || !(name == "*" || name.start_with?("*."))

        schema = tinkick_schema
        pattern = /\A#{Regexp.escape(name).gsub('\*', '.*')}\z/m
        expanded = tinkick_wildcard_candidates(schema, mode).grep(pattern).map { |field| { field => mode } } #: model_fields
        tinkick_validate_fields(schema, expanded, match)
        expanded
      end
    end

    def tinkick_index_analysis(field_name, field)
      # @type self: singleton(ActiveRecord::Base)
      schema = tinkick_schema
      cached = schema[:analysis][field_name]
      return cached if cached

      expression = field.canonical_expression if field.json?
      configurations = schema[:index_configurations].filter_map do |index|
        matching = field.json? ? index[:expression] == expression : index[:column_name] == field_name
        index[:analysis] if matching
      end.uniq
      if configurations.empty?
        raise Error, "#{name}.#{field_name} requires a valid, nonpartial TIN index for token matching; add it with a Rails migration"
      end
      if configurations.length > 1
        raise Error, "#{name}.#{field_name} has TIN indexes with conflicting tokenization options; use the same analysis configuration for this indexed source"
      end

      schema[:analysis][field_name] = configurations.fetch(0)
    end

    private

    def tinkick_default_fields(schema)
      schema[:data_fields].select do |field|
        column = schema[:columns].fetch(field)
        array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
        !array && [:text, :citext].include?(column.type)
      end
    end

    def tinkick_wildcard_candidates(schema, mode)
      # @type self: singleton(ActiveRecord::Base)
      options = tinkick_options
      fields = options&.fetch(:searchable) || tinkick_default_fields(schema)
      candidates = fields.map { |field| field.is_a?(Hash) ? field.keys.first.to_s : field.to_s }
      default_match = options ? options[:match] : :word
      return default_match == :word ? candidates : [] if [:word, :phrase].include?(mode)
      return candidates if default_match == mode

      # Searchkick maps partial fields only for the model's match mode or an
      # explicit declaration. Concrete field queries keep their own semantics.
      declared = case mode
      when :word_start then options&.fetch(:word_start)
      when :word_middle then options&.fetch(:word_middle)
      when :word_end then options&.fetch(:word_end)
      when :text_start then options&.fetch(:text_start)
      when :text_middle then options&.fetch(:text_middle)
      when :text_end then options&.fetch(:text_end)
      else return candidates
      end
      candidates & (declared || []).map(&:to_s)
    end

    def tinkick_schema
      # @type self: singleton(ActiveRecord::Base)
      with_connection do |connection|
        unless connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
          raise Error, "Tinkick requires PostgreSQL with the TIN extension"
        end

        columns = columns_hash
        pool = connection_pool
        cached = @tinkick_schema
        return cached if cached && cached[:columns].equal?(columns) && cached[:pool].equal?(pool)

        unless connection.extension_enabled?("tin")
          raise Error, "#{name} requires TIN; add a Rails migration with enable_extension :tin"
        end

        data_fields = tinkick_data_fields(columns)
        missing = data_fields - columns.keys
        unless missing.empty?
          raise MissingFieldError, "#{name} has no columns #{missing.join(", ")}; add persisted or generated columns with a Rails migration. Ruby search_data values are not persisted by Tinkick"
        end

        indexes = connection.select_all(Arel.sql(<<~SQL, table_name)).to_a
          SELECT attribute.attname AS column_name, pg_catalog.pg_get_expr(index.indexprs, index.indrelid) AS expression,
            array_to_json(index_class.reloptions)::text AS options
          FROM pg_catalog.pg_index AS index
          JOIN pg_catalog.pg_class AS index_class ON index_class.oid = index.indexrelid
          JOIN pg_catalog.pg_am AS access_method ON access_method.oid = index_class.relam
          LEFT JOIN pg_catalog.pg_attribute AS attribute
            ON attribute.attrelid = index.indrelid AND attribute.attnum = index.indkey[0]
          WHERE index.indrelid = pg_catalog.to_regclass(?)
            AND access_method.amname = 'tin'
            AND index.indisvalid AND index.indisready
            AND index.indpred IS NULL AND index.indnkeyatts = 1
        SQL
        index_fields = indexes.filter_map do |index|
          value = index["column_name"]
          value if value.is_a?(String)
        end
        index_expressions = indexes.filter_map do |index|
          value = index["expression"]
          value if value.is_a?(String)
        end
        configurations = indexes.map do |index|
          options = index["options"]
          values = options.is_a?(String) ? JSON.parse(options) : [] #: Array[String]
          analysis = WordMatch::ANALYSIS_DEFAULTS.dup
          values.each do |option|
            key, value = option.split("=", 2)
            analysis[key] = value if key && value && analysis.key?(key)
          end
          column = index["column_name"]
          expression = index["expression"]
          { column_name: column.is_a?(String) ? column : nil,
            expression: expression.is_a?(String) ? expression : nil, analysis: analysis }
        end #: Array[index_configuration]
        @tinkick_schema = { columns: columns, pool: pool, data_fields: data_fields, index_fields: index_fields,
                           index_expressions: index_expressions, index_configurations: configurations, analysis: {} }
      end
    end

    def tinkick_data_fields(columns)
      # @type self: singleton(ActiveRecord::Base)
      return columns.keys unless method_defined?(:search_data)

      begin
        data = new.public_send(:search_data)
      rescue StandardError => error
        raise Error, "#{name}#search_data must run safely on a new instance (#{error.class}). Move derived data to persisted or generated columns with Rails migrations and return their keys without requiring saved records or associations"
      end
      raise Error, "#{name}#search_data must return a Hash of column names" unless data.is_a?(Hash)

      data.keys.map(&:to_s)
    end

    def tinkick_validate_fields(schema, fields, match)
      # @type self: singleton(ActiveRecord::Base)
      fields.each do |entry|
        if entry.is_a?(Hash)
          raise ArgumentError, "Each field hash must contain one field and match mode" unless entry.length == 1

          field, mode = entry.to_a.fetch(0)
        else
          field = entry
          mode = match
        end
        field = field.to_s
        descriptor = SearchField.new(self, field, match: mode)
        sql_match = [:exact, :text_start, :text_middle, :text_end].include?(mode)
        next if sql_match

        if descriptor.json? && !schema[:index_fields].include?(field) && schema[:index_expressions].include?(descriptor.canonical_expression)
          schema[:index_fields] << field
        end
        unless schema[:index_fields].include?(field)
          if descriptor.json?
            raise Error, "#{name}.#{field} requires a valid, nonpartial TIN expression index; generate a Rails migration with bin/rails generate tinkick:index #{table_name.inspect} #{field.inspect}, then run bin/rails db:migrate"
          end
          raise Error, "#{name}.#{field} requires a valid, nonpartial TIN index on the column; add a Rails migration with add_index #{table_name.inspect}, #{field.inspect}, using: :tin"
        end
      end
    end
  end
end
