# frozen_string_literal: true

require_relative "relation"
require_relative "search_field"
require "json"

require_relative "model/declaration"

module Tinkick
  module Model
    include Declaration

    def tinkick_search(term = "*", fields: nil, misspellings: true, where: {}, order: nil, limit: nil, offset: nil, page: nil, per_page: nil, padding: nil, match: nil, operator: "and", load: true, total_entries: nil, countless: false, keyset: false, after: nil, aggs: nil, smart_aggs: true, includes: nil, model_includes: nil, scope_results: nil, exclude: nil, select: nil, highlight: nil, boost_by: nil, boost_where: nil, boost: nil, boost_by_recency: nil, conversions: nil, conversions_v2: nil, conversions_term: nil, conversions_v1: Relation::NO_DEFAULT_VALUE, block: nil, tinql: nil, &query_block)
      # @type self: singleton(ActiveRecord::Base)
      # @type var conversions_v1: conversion_fields | Relation::DefaultValue
      raise ArgumentError, "Pass either block: or a Ruby block, not both" if block && query_block
      block ||= query_block
      conversions = conversions_v1 unless conversions_v1.is_a?(Relation::DefaultValue)
      options = tinkick_options
      raise Error, "Declare tinkick on #{name} before calling tinkick_search" unless options

      schema = tinkick_schema
      (options[:highlight] || []).each { |field| SearchField.new(self, field.to_s, match: :exact) }
      tinkick_validate_filterable(schema, options[:filterable] || [])
      fields ||= options[:default_fields] || options[:searchable] || tinkick_default_fields(schema)
      match ||= options[:match]
      selected = tinkick_expand_fields(fields, match: match)
      selected_names = selected.map { |field| (field.is_a?(Hash) ? field.keys.first.to_s : field.to_s).split("^", 2).fetch(0) }
      declared = (options[:searchable] || []).reject { |field| selected_names.include?(field.to_s) }
      tinkick_validate_fields(schema, declared + selected, match)

      Relation.new(self, term, base_scope: all, fields: fields, misspellings: misspellings,
        where: where, order: order, limit: limit, offset: offset, page: page,
        per_page: per_page, padding: padding, match: match,
        operator: operator, load: load, total_entries: total_entries,
        countless: countless, keyset: keyset, after: after, aggs: aggs, smart_aggs: smart_aggs, includes: includes, model_includes: model_includes, scope_results: scope_results, exclude: exclude, select: select, highlight: highlight, boost_by: boost_by, boost_where: boost_where, boost: boost, boost_by_recency: boost_by_recency, conversions: conversions, conversions_v2: conversions_v2, conversions_term: conversions_term, block: block, tinql: tinql)
    end

    def tinkick_expand_fields(fields, match:)
      # @type self: singleton(ActiveRecord::Base)
      boosts = {} #: Hash[[String, Symbol], Float]
      normalized = fields.map do |entry|
        if entry.is_a?(Hash)
          raise ArgumentError, "Each field hash must contain one field and match mode" unless entry.length == 1

          name, mode = entry.to_a.fetch(0)
        else
          name = entry
          mode = match
        end
        parts = name.to_s.split("^", 2)
        field = parts.fetch(0)
        suffix = parts[1]
        boosts[[field, mode]] = suffix.to_f if suffix
        [field, mode]
      end #: Array[[String, Symbol]]
      normalized.flat_map do |name, mode|
        boost = boosts[[name, mode]]
        if boost
          raise ArgumentError, "Field boost must be finite and nonnegative" unless boost.finite? && boost >= 0
        end
        selector = boost ? "#{name}^#{boost}" : name
        next [{ selector => mode }] if mode == :exact || !(name == "*" || name.start_with?("*."))

        schema = tinkick_schema
        pattern = /\A#{Regexp.escape(name).gsub('\*', '.*')}\z/m
        expanded = tinkick_wildcard_candidates(schema, mode).grep(pattern).map do |field|
          { (boost ? "#{field}^#{boost}" : field) => mode }
        end #: model_fields
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

      analysis = configurations.fetch(0)
      tinkick_validate_analysis(field_name, analysis)
      schema[:analysis][field_name] = analysis
    end

    private

    def tinkick_validate_analysis(field_name, analysis)
      # @type self: singleton(ActiveRecord::Base)
      options = tinkick_options
      return unless options

      expected = {} #: Hash[String, String]
      if options.key?(:case_sensitive)
        expected["case_folding"] = options[:case_sensitive] ? "preserve" : "fold"
      end
      if options.key?(:special_characters)
        expected["accent_folding"] = options[:special_characters] == false ? "preserve" : "fold"
      end
      expected.each do |setting, value|
        next if analysis[setting] == value

        raise Error, "#{name}.#{field_name} has TIN #{setting}=#{analysis[setting]}, but its model declaration requires #{setting}=#{value}; rebuild the affected TIN index with this setting in a Rails migration, then reset_column_information or restart application processes. Changing tokenization settings alone does not update existing indexed rows"
      end
    end

    def tinkick_validate_filterable(schema, fields)
      # @type self: singleton(ActiveRecord::Base)
      fields.each do |field|
        root, *path = field.to_s.split(".", -1)
        column = schema[:columns][root.to_s]
        unless column
          raise MissingFieldError, "#{name} has no column #{root.inspect}; add it with a Rails migration before declaring it filterable"
        end
        next if path.empty?

        array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
        unless column.type == :jsonb && !array
          raise InvalidQueryError, "#{name}.#{root} requires a nonarray JSONB column for dotted filterable fields; add or convert the column with a Rails migration"
        end
        raise ArgumentError, "filterable JSONB paths require nonempty components" if path.any?(&:empty?)
      end
    end

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
          raise MissingFieldError, "#{name} has no columns #{missing.join(", ")}; add persisted or generated columns with a Rails migration. Ruby schema-check values are not persisted by Tinkick"
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
          analysis = QueryText::ANALYSIS_DEFAULTS.dup
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
      hook = if method_defined?(:tinkick_search_data)
        :tinkick_search_data
      elsif !Gem.loaded_specs.key?("searchkick") && method_defined?(:search_data)
        :search_data
      end
      return columns.keys unless hook

      begin
        data = new.public_send(hook)
      rescue StandardError => error
        raise Error, "#{name}##{hook} must run safely on a new instance (#{error.class}). Move derived data to persisted or generated columns with Rails migrations and return their keys without requiring saved records or associations"
      end
      raise Error, "#{name}##{hook} must return a Hash of column names" unless data.is_a?(Hash)

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
        field = field.to_s.split("^", 2).fetch(0)
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
