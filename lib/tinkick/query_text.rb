# frozen_string_literal: true

require "active_record"

module Tinkick
  class QueryText
    def initialize(connection)
      @connection = connection
    end

    def compile(term, operator: "and", match: :word, misspellings: false)
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(operator)
      raise ArgumentError, "Unsupported match mode: #{match.inspect}" unless [:word, :phrase].include?(match)
      settings = fuzzy_settings(misspellings)

      return "*" if term == "*"

      words = tokens(term)
      return "" if words.empty?
      return quote(term) if match == :phrase

      separator = " #{operator.upcase} "
      exact = words.map { |word| literal(word) }.join(separator)
      return exact unless settings

      distance, prefix = settings
      return exact if distance.zero?

      if words.any? { |word| ["*", "#"].include?(word) }
        raise ArgumentError, "Fuzzy keycap matching is not supported yet; use misspellings: false"
      end

      fuzzy = words.map { |word| "#{word}~#{prefix}:#{distance}" }.join(separator)
      "((#{exact})^10 OR (#{fuzzy})^1)"
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

    def fuzzy_settings(options)
      return if options == false

      unless options.is_a?(Hash) && options[:transpositions] == false
        raise ArgumentError, "Searchkick transpositions are not supported yet; specify misspellings: { transpositions: false } for native TIN edits"
      end

      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      prefix = options.fetch(:prefix_length, 0)
      unless distance.is_a?(Integer) && distance >= 0 && prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Misspellings distance and prefix_length must be nonnegative integers"
      end

      [distance, prefix]
    end
  end
end
