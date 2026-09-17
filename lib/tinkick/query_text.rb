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
      settings = fuzzy_settings(misspellings)

      return "*" if term == "*"

      words = tokens(term)
      return "" if words.empty?
      return quote(term) if match == :phrase

      separator = " #{operator.upcase} "
      if [:word_start, :word_middle, :word_end].include?(match)
        if settings && settings.first.positive?
          raise ArgumentError, "Fuzzy partial-word matching is not implemented yet; use misspellings: false"
        end
        # Searchkick indexes word ngrams from 1 through 50 Unicode characters.
        return "" if operator == "and" && words.any? { |word| word.length > 50 }

        words = words.reject { |word| word.length > 50 }
        return words.map { |word| partial(word, match) }.join(separator)
      end

      exact = words.map { |word| literal(word) }.join(separator)
      return exact unless settings

      distance, prefix, transpositions = settings
      return exact if distance.zero?

      if words.any? { |word| ["*", "#"].include?(word) }
        raise ArgumentError, "Fuzzy keycap matching is not supported yet; use misspellings: false"
      end

      words.map { |word| fuzzy(word, distance, prefix, transpositions) }.join(separator)
    end

    private

    def tokens(term)
      bind = ActiveRecord::Relation::QueryAttribute.new("term", term, ActiveRecord::Type::String.new)
      # The catalog source routes this helper to PostgreSQL on PlanetScale.
      # @type var values: Array[String]
      values = @connection.select_values(
        "SELECT tin.tokenize($1) FROM pg_extension WHERE extname = 'tin'",
        "Tinkick Tokenize",
        [bind],
      )
      values
    end

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
