# frozen_string_literal: true

require "json"
require_relative "extensions"
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

    def predicate(field_name, term, operator: "and", match: :word, misspellings:)
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(operator)
      unless [:word, :word_start, :word_middle, :word_end].include?(match)
        raise ArgumentError, "Unsupported token match mode: #{match.inspect}"
      end
      prefix, transpositions = settings(misspellings, match)
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
        if match != :word
          possible = words.select do |word|
            minimum, maximum = partial_lengths(word, prefix)
            minimum <= maximum
          end
          next ["FALSE", []] if operator == "and" && possible.length != words.length

          words = possible
        end
        next ["FALSE", []] if words.empty?

        function = if transpositions
          Functions.require!(@model)
        else
          schema = Extensions.require!(@model, "fuzzystrmatch")
          "#{connection.quote_column_name(schema)}.levenshtein_less_equal"
        end
        candidates = words.map { |word| candidate(word, prefix, match) }.join(" #{operator.upcase} ")
        binds = [candidates] #: Array[filter_scalar]
        refinements = words.map do |word|
          fixed = [prefix, word.length].min
          binds << word.chars.first(fixed).join << word.chars.drop(fixed).join
          refinement(field.text_sql, options, word, prefix, match, function)
        end
        if match == :word
          @model.logger&.warn("Tinkick: two-edit transposition matching checks tokens from native TIN candidates with SQL edit distance and can bypass native top-k ranking. Broad candidates or long fields can be expensive; inspect EXPLAIN ANALYZE for your workload.")
        else
          @model.logger&.warn("Tinkick: two-edit partial matching enumerates bounded grams from TIN candidate tokens and can bypass native top-k ranking and sort matches. Without a fixed prefix, candidates can cover most tokens; word_middle also checks each position. Inspect EXPLAIN ANALYZE before using this on long fields or large result sets.")
        end
        ["(#{field.text_sql} ==> ?) AND (#{refinements.join(" #{operator.upcase} ")})", binds]
      end
    end

    private

    def settings(options, match)
      unless options.is_a?(Hash)
        raise ArgumentError, "Two-edit word matching requires a misspellings options hash"
      end
      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?
      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      transpositions = options.fetch(:transpositions, true)
      unless distance.is_a?(Integer) && distance == 2
        raise ArgumentError, "This token refinement requires edit_distance: 2"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end
      raise ArgumentError, "Whole-word refinement requires transpositions: true" if match == :word && !transpositions
      prefix = options.fetch(:prefix_length, 0)
      unless prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Misspellings prefix_length must be a nonnegative integer"
      end

      [prefix, transpositions]
    end

    def candidate(word, prefix, match)
      fixed = [prefix, word.length].min
      # Two restricted transpositions require at most four Levenshtein edits.
      if match == :word && /\A[\p{L}\p{M}\p{N}]+\z/.match?(word) && word == word.downcase
        return "#{word}~#{fixed}:4"
      end

      # Regex addresses dictionary tokens directly when fuzzy syntax would
      # reinterpret punctuation or a case-preserved TINQL keyword.
      literal = Regexp.escape(word.chars.first(fixed).join)
      if match == :word
        minimum = [[1, word.length - 2].max - fixed, 0].max
        maximum = word.length + 2 - fixed
      else
        minimum, maximum = partial_lengths(word, prefix)
        minimum -= fixed
        maximum -= fixed
      end
      leading = [:word_middle, :word_end].include?(match) ? ".*" : ""
      trailing = [:word_start, :word_middle].include?(match) ? ".*" : ""
      "MATCHES #{leading}#{literal}.{#{minimum},#{maximum}}#{trailing}"
    end

    def partial_lengths(word, prefix)
      [[1, word.length - 2, [prefix, word.length].min].max, [50, word.length + 2].min]
    end

    def refinement(column_sql, options, word, prefix, match, function)
      fixed = [prefix, word.length].min
      value = "tinkick_tokens.value"
      joins = ""
      if match != :word
        minimum, maximum = partial_lengths(word, prefix)
        joins = "CROSS JOIN LATERAL generate_series(#{minimum}, LEAST(#{maximum}, char_length(tinkick_tokens.value))) AS tinkick_lengths(length)"
        if match == :word_middle
          joins += " CROSS JOIN LATERAL generate_series(1, char_length(tinkick_tokens.value) - tinkick_lengths.length + 1) AS tinkick_offsets(position)"
        end
        position = case match
        when :word_start then "1"
        when :word_end then "char_length(tinkick_tokens.value) - tinkick_lengths.length + 1"
        else "tinkick_offsets.position"
        end
        value = "substring(tinkick_tokens.value FROM #{position} FOR tinkick_lengths.length)"
      end
      <<~SQL
        EXISTS (
          SELECT 1 FROM tin.tokenize(#{column_sql}#{options}) AS tinkick_tokens(value)
          #{joins}
          WHERE left(#{value}, #{fixed}) COLLATE "C" = ? COLLATE "C"
            AND #{function}(substring(#{value} FROM #{fixed + 1}), ?, 2) <= 2
        )
      SQL
    end

    public

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
        raise Error, "#{@model.name}.#{field_name} requires a valid, nonpartial TIN index for token matching; add it with a Rails migration"
      end
      if configurations.length > 1
        raise Error, "#{@model.name}.#{field_name} has TIN indexes with conflicting tokenization options; use the same analysis configuration for this indexed source"
      end

      configurations.fetch(0)
    end
  end
end
