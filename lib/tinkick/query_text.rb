# frozen_string_literal: true

require "active_record"

module Tinkick
  class QueryText
    def initialize(connection)
      @connection = connection
    end

    def compile(term, operator: "and", match: :word, misspellings: false)
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(operator)
      raise ArgumentError, "Unsupported match mode: #{match.inspect}" unless [:word, :phrase, :word_start, :word_middle, :word_end].include?(match)
      settings = match == :phrase ? nil : fuzzy_settings(misspellings)

      return "*" if term == "*"

      words = tokens(term)
      return "" if words.empty?
      return quote(term) if match == :phrase

      separator = " #{operator.upcase} "
      if [:word_start, :word_middle, :word_end].include?(match)
        queries = if settings && settings.first.positive?
          distance, prefix, transpositions = settings
          words.map { |word| fuzzy_pattern(word, match, distance, prefix, transpositions) }
        else
          words.map { |word| partial(word, match) }
        end
        return "" if operator == "and" && queries.any?(&:empty?)

        return queries.reject(&:empty?).join(separator)
      end

      exact = words.map { |word| literal(word) }.join(separator)
      return exact unless settings

      distance, prefix, transpositions = settings
      return exact if distance.zero?

      words.map do |word|
        if ["*", "#"].include?(word)
          fuzzy_pattern(word, :word, distance, prefix, transpositions)
        else
          fuzzy(word, distance, prefix, transpositions)
        end
      end.join(separator)
    end

    def exclusion(term, words:, match:)
      return "" if words.empty?
      return quote(term) if [:word, :phrase].include?(match)

      return "" if words.any? { |word| word.length > 50 }

      leading = match == :word_start ? "" : ".*"
      trailing = match == :word_end ? "" : ".*"
      patterns = words.map { |word| "MATCHES #{leading}#{Regexp.escape(word)}#{trailing}" }
      patterns.map { |pattern| "(#{pattern})" }.join(" THEN/0 ")
    end

    def tokens(term, analysis: {})
      names = ["tokenizer", "case_folding", "accent_folding", "long_tokens", "max_token_bytes", "graphemes", "position_gaps"]
      raise ArgumentError, "Unknown TIN analysis options" unless (analysis.keys - names).empty?

      options = analysis.map do |key, value|
        argument = key == "max_token_bytes" ? Integer(value, 10) : value
        ", #{key} => #{@connection.quote(argument)}"
      end.join
      bind = ActiveRecord::Relation::QueryAttribute.new("term", term, ActiveRecord::Type::String.new)
      # The catalog source routes this helper to PostgreSQL on PlanetScale.
      # @type var values: Array[String]
      values = @connection.select_values(
        "SELECT tin.tokenize($1#{options}) FROM pg_extension WHERE extname = 'tin'",
        "Tinkick Tokenize",
        [bind],
      )
      values
    end

    private

    def quote(term)
      escaped = term.gsub(/["\\_\[\]]/) { |character| "\\#{character}" }
      "\"#{escaped}\""
    end

    def literal(word)
      # Keycap emoji normalize to punctuation that otherwise analyzes to nothing.
      return "MATCHES #{Regexp.escape(word)}" if ["*", "#"].include?(word)

      quote(word)
    end

    def partial(word, match)
      # Searchkick indexes word ngrams from 1 through 50 Unicode characters.
      return "" if word.length > 50

      if ["*", "#"].include?(word)
        prefix = match == :word_start ? "" : ".*"
        suffix = match == :word_end ? "" : ".*"
        return "MATCHES #{prefix}#{Regexp.escape(word)}#{suffix}"
      end

      escaped = word.gsub(/[\\*?]/) { |character| "\\#{character}" }
      prefix = match == :word_start ? "" : "*"
      suffix = match == :word_end ? "" : "*"
      "#{prefix}#{escaped}#{suffix}"
    end

    def fuzzy_pattern(word, match, distance, prefix, transpositions)
      unless distance == 1
        raise ArgumentError, "This fuzzy match mode currently supports edit_distance: 0 or 1"
      end

      characters = word.chars.map { |character| Regexp.escape(character) }
      alternatives = [characters]
      fixed = [prefix, characters.length].min
      (fixed...characters.length).each do |index|
        substituted = characters.dup
        substituted[index] = "."
        alternatives << substituted

        deleted = characters.dup
        deleted.delete_at(index)
        alternatives << deleted

        if transpositions && index + 1 < characters.length
          swapped = characters.dup
          swapped[index] = characters.fetch(index + 1)
          swapped[index + 1] = characters.fetch(index)
          alternatives << swapped
        end
      end
      (fixed..characters.length).each do |index|
        alternatives << characters.dup.insert(index, ".")
      end

      patterns = alternatives.select { |candidate| candidate.length.between?(1, 50) }.map(&:join).uniq
      return "" if patterns.empty?

      leading = [:word_middle, :word_end].include?(match) ? ".*" : ""
      trailing = [:word_start, :word_middle].include?(match) ? ".*" : ""
      "MATCHES #{leading}(#{patterns.join('|')})#{trailing}"
    end

    def fuzzy(word, distance, prefix, transpositions)
      native = "#{word}~#{prefix}:#{distance}"
      return native unless transpositions

      characters = word.chars
      alternatives = [native]
      (prefix...(characters.length - 1)).each do |index|
        next if characters.fetch(index) == characters.fetch(index + 1)

        swapped = characters.dup
        swapped[index] = characters.fetch(index + 1)
        swapped[index + 1] = characters.fetch(index)
        alternatives << "MATCHES #{Regexp.escape(swapped.join)}"
      end

      alternatives.length == 1 ? native : "(#{alternatives.join(' OR ')})"
    end

    def fuzzy_settings(options)
      return if options == false

      options = { transpositions: true } if options == true
      raise ArgumentError, "Misspellings must be true, false, or an options hash" unless options.is_a?(Hash)

      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      prefix = options.fetch(:prefix_length, 0)
      transpositions = options.fetch(:transpositions, true)
      unless distance.is_a?(Integer) && distance >= 0 && prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Misspellings distance and prefix_length must be nonnegative integers"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end
      if transpositions && distance > 1
        raise ArgumentError, "Misspellings transpositions currently support edit_distance: 0 or 1; use transpositions: false for larger native TIN distances"
      end

      [distance, prefix, transpositions]
    end
  end
end
