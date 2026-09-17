# frozen_string_literal: true

require "json"
require_relative "functions"
require_relative "search_field"

module Tinkick
  class WordMatch
    ANALYSIS_DEFAULTS = {
      "tokenizer" => "unicode", "case_folding" => "fold", "accent_folding" => "fold",
      "long_tokens" => "split", "max_token_bytes" => "256",
      "graphemes" => "emoji", "position_gaps" => "preserve",
    }.freeze

    def initialize(model)
      @model = model
    end

    def predicate(field_name, term, operator: "and", misspellings:)
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(operator)
      prefix = prefix_length(misspellings)
      field = SearchField.new(@model, field_name)
      analysis = index_analysis(field_name, field)
      @model.with_connection do |connection|
        options = analysis.map do |key, value|
          argument = key == "max_token_bytes" ? Integer(value, 10) : value
          ", #{key} => #{connection.quote(argument)}"
        end.join
        words = connection.select_values(Arel.sql(<<~SQL, term)).map(&:to_s)
          SELECT tin.tokenize(?#{options}) FROM pg_catalog.pg_extension WHERE extname = 'tin'
        SQL
        next ["FALSE", []] if words.empty?

        function = Functions.require!(@model)
        candidates = words.map { |word| candidate(word, prefix) }.join(" #{operator.upcase} ")
        binds = [candidates] #: Array[filter_scalar]
        refinements = words.map do |word|
          fixed = [prefix, word.length].min
          binds << word.chars.first(fixed).join << word.chars.drop(fixed).join
          <<~SQL
            EXISTS (
              SELECT 1 FROM tin.tokenize(#{field.text_sql}#{options}) AS tinkick_tokens(value)
              WHERE left(tinkick_tokens.value, #{fixed}) COLLATE "C" = ? COLLATE "C"
                AND #{function}(substring(tinkick_tokens.value FROM #{fixed + 1}), ?, 2) <= 2
            )
          SQL
        end
        @model.logger&.warn("Tinkick: two-edit transposition matching checks tokens from native TIN candidates with SQL edit distance and can bypass native top-k ranking. Broad candidates or long fields can be expensive; inspect EXPLAIN ANALYZE for your workload.")
        ["(#{field.text_sql} ==> ?) AND (#{refinements.join(" #{operator.upcase} ")})", binds]
      end
    end

    private

    def prefix_length(options)
      unless options.is_a?(Hash)
        raise ArgumentError, "Two-edit word matching requires a misspellings options hash"
      end
      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?
      unless options.fetch(:edit_distance, options.fetch(:distance, 1)) == 2 && options.fetch(:transpositions, true) == true
        raise ArgumentError, "This word refinement requires edit_distance: 2 and transpositions: true"
      end
      prefix = options.fetch(:prefix_length, 0)
      unless prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Misspellings prefix_length must be a nonnegative integer"
      end

      prefix
    end

    def candidate(word, prefix)
      fixed = [prefix, word.length].min
      # Two restricted transpositions require at most four Levenshtein edits.
      if /\A[\p{L}\p{M}\p{N}]+\z/.match?(word) && word == word.downcase
        return "#{word}~#{fixed}:4"
      end

      # Regex addresses dictionary tokens directly when fuzzy syntax would
      # reinterpret punctuation or a case-preserved TINQL keyword.
      literal = Regexp.escape(word.chars.first(fixed).join)
      minimum = [[1, word.length - 2].max - fixed, 0].max
      maximum = word.length + 2 - fixed
      "MATCHES #{literal}.{#{minimum},#{maximum}}"
    end

    def index_analysis(field_name, field)
      expression = field.canonical_expression if field.json?
      indexes = @model.with_connection do |connection|
        connection.select_all(Arel.sql(<<~SQL, @model.table_name)).to_a
          SELECT attribute.attname AS column_name,
            pg_catalog.pg_get_expr(index.indexprs, index.indrelid) AS expression,
            array_to_json(index_class.reloptions)::text AS options
          FROM pg_catalog.pg_index AS index
          JOIN pg_catalog.pg_class AS index_class ON index_class.oid = index.indexrelid
          JOIN pg_catalog.pg_am AS access_method ON access_method.oid = index_class.relam
          LEFT JOIN pg_catalog.pg_attribute AS attribute
            ON attribute.attrelid = index.indrelid AND attribute.attnum = index.indkey[0]
          WHERE index.indrelid = pg_catalog.to_regclass(?)
            AND access_method.amname = 'tin' AND index.indisvalid AND index.indisready
            AND index.indpred IS NULL AND index.indnkeyatts = 1
        SQL
      end
      configurations = indexes.filter_map do |index|
        matching = field.json? ? index["expression"] == expression : index["column_name"] == field_name
        next unless matching

        options = index["options"]
        values = options.is_a?(String) ? JSON.parse(options) : [] #: Array[String]
        analysis = ANALYSIS_DEFAULTS.dup
        values.each do |option|
          key, value = option.split("=", 2)
          analysis[key] = value if key && value && analysis.key?(key)
        end
        analysis
      end.uniq
      if configurations.empty?
        raise Error, "#{@model.name}.#{field_name} requires a valid, nonpartial TIN index for fuzzy word matching; add it with a Rails migration"
      end
      if configurations.length > 1
        raise Error, "#{@model.name}.#{field_name} has TIN indexes with conflicting tokenization options; use the same analysis configuration for this indexed source"
      end

      configurations.fetch(0)
    end
  end
end
