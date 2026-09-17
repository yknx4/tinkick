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
      raise ArgumentError, "Misspellings are not implemented yet" unless misspellings == false

      return "*" if term == "*"

      words = tokens(term)
      return "" if words.empty?
      return quote(term) if match == :phrase

      words.map { |word| literal(word) }.join(" #{operator.upcase} ")
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
  end
end
