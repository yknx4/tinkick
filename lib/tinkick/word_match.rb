# frozen_string_literal: true

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

    def predicate(field_name, term, operator: "and", match: :word, misspellings:, excluded: nil)
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(operator)
      unless [:word, :word_start, :word_middle, :word_end].include?(match)
        raise ArgumentError, "Unsupported token match mode: #{match.inspect}"
      end
      distance, prefix, transpositions = settings(misspellings, match)
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

        function = if match == :word && (distance != 2 || !transpositions)
          Functions.require_edit_distance!(@model)
        elsif transpositions
          Functions.require!(@model)
        else
          schema = Extensions.require!(@model, "fuzzystrmatch")
          "#{connection.quote_column_name(schema)}.levenshtein_less_equal"
        end
        candidates = words.map { |word| candidate(word, prefix, match, distance, transpositions) }.join(" #{operator.upcase} ")
        candidates = "(#{candidates}) AND NOT (#{excluded})" if excluded
        binds = [candidates] #: Array[filter_scalar]
        refinements = words.map do |word|
          fixed = [prefix, word.length].min
          binds << word.chars.first(fixed).join << word.chars.drop(fixed).join
          refinement(field.text_sql, options, word, prefix, match, function, distance, transpositions)
        end
        if match == :word
          @model.logger&.warn("Tinkick: fuzzy literal or two-edit transposition matching checks tokens from native TIN candidates with SQL edit distance and can bypass native top-k ranking. Broad candidates or long fields can be expensive; inspect EXPLAIN ANALYZE for your workload.")
        else
          @model.logger&.warn("Tinkick: two-edit partial matching enumerates bounded grams from TIN candidate tokens and can bypass native top-k ranking and sort matches. Without a fixed prefix, candidates can cover most tokens; word_middle also checks each position. Inspect EXPLAIN ANALYZE before using this on long fields or large result sets.")
        end
        ["(#{field.text_sql} ==> ?) AND (#{refinements.join(" #{operator.upcase} ")})", binds]
      end
    end

    private

    def settings(options, match)
      options = { transpositions: true } if options == true
      unless options.is_a?(Hash)
        raise ArgumentError, "Token refinement requires true or a misspellings options hash"
      end
      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?
      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      transpositions = options.fetch(:transpositions, true)
      unless distance.is_a?(Integer) && distance.positive? && (match == :word || distance == 2)
        raise ArgumentError, "Token refinement requires a positive edit_distance, or edit_distance: 2 for partial matching"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end
      prefix = options.fetch(:prefix_length, 0)
      unless prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Misspellings prefix_length must be a nonnegative integer"
      end

      [distance, prefix, transpositions]
    end

    def candidate(word, prefix, match, distance, transpositions)
      fixed = [prefix, word.length].min
      # Two restricted transpositions require at most four Levenshtein edits.
      if match == :word && /\A[\p{L}\p{M}\p{N}]+\z/.match?(word) && word == word.downcase
        return "#{word}~#{fixed}:#{distance * (transpositions ? 2 : 1)}"
      end

      # Regex addresses dictionary tokens directly when fuzzy syntax would
      # reinterpret punctuation or a case-preserved TINQL keyword.
      literal = Regexp.escape(word.chars.first(fixed).join)
      if match == :word
        minimum = [[1, word.length - distance].max - fixed, 0].max
        maximum = word.length + distance - fixed
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

    def refinement(column_sql, options, word, prefix, match, function, distance, transpositions)
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
      arguments = "substring(#{value} FROM #{fixed + 1}), ?, #{distance}"
      arguments += ", #{transpositions}" if function == "tinkick.edit_distance"
      <<~SQL
        EXISTS (
          SELECT 1 FROM tin.tokenize(#{column_sql}#{options}) AS tinkick_tokens(value)
          #{joins}
          WHERE left(#{value}, #{fixed}) COLLATE "C" = ? COLLATE "C"
            AND #{function}(#{arguments}) <= #{distance}
        )
      SQL
    end

    public

    def index_analysis(field_name, field)
      @model.tinkick_index_analysis(field_name, field)
    end
  end
end
