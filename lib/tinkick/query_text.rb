# frozen_string_literal: true

require "active_record"
require_relative "errors"

module Tinkick
  class QueryText
    ANALYSIS_DEFAULTS = {
      "tokenizer" => "unicode", "case_folding" => "fold", "accent_folding" => "fold",
      "long_tokens" => "split", "max_token_bytes" => "256",
      "graphemes" => "emoji", "position_gaps" => "preserve",
    }.freeze
    # Whitespace-separated alphabetic words are one native unicode token, so TIN
    # can fold them itself. Other input keeps the exact tokenize round trip.
    NATIVE_WORD = /\A_*[\p{Latin}\p{Greek}\p{Cyrillic}\p{Nd}][\p{Latin}\p{Greek}\p{Cyrillic}\p{Nd}\p{M}_]*\z/
    EDGE_PUNCTUATION = /\A[\p{P}&&[^_]]+|[\p{P}&&[^_]]+\z/
    # Sorts after every character that can continue a native unicode token while
    # still joining it, so a term-dictionary range covers each prefix completion.
    RANGE_PAD = "\u{1FBF9}"
    WILDCARD_UNSAFE = /[\s"()\[\]~^*?\\:]/

    def initialize(connection)
      @connection = connection
    end

    def compile(term, operator: "and", match: :word, misspellings: false, analysis: {})
      raise ArgumentError, "operator must be and or or" unless ["and", "or"].include?(operator)
      raise ArgumentError, "Unsupported match mode: #{match.inspect}" unless [:word, :phrase, :word_start, :word_middle, :word_end].include?(match)
      settings = match == :phrase ? nil : fuzzy_settings(misspellings)

      return "*" if term == "*"

      words = words(term, analysis: analysis)
      return "" if words.empty?
      return quote(term) if match == :phrase

      separator = " #{operator.upcase} "
      if [:word_start, :word_middle, :word_end].include?(match)
        if settings && settings.first.positive?
          raise NotImplementedError, "Fuzzy wildcard matching is not supported by native TIN; use misspellings: false for token prefix, substring, or suffix matching"
        end
        return words.map { |word| partial(word, match, analysis) }.join(separator)
      end

      exact = words.map { |word| literal(word) }.join(separator)
      return exact unless settings

      distance, prefix = settings
      return exact if distance.zero?

      words.map { |word| fuzzy(word, distance, prefix, analysis) }.join(separator)
    end

    def exclusion(term, words:, match:, analysis: {})
      return "" if words.empty?
      return quote(term) if [:word, :phrase].include?(match)

      words.map { |word| "(#{partial(word, match, analysis)})" }.join(" THEN/0 ")
    end

    def words(term, analysis: {})
      native_words(term, analysis) || tokens(term, analysis: analysis)
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

    def native_words(term, analysis)
      return unless analysis.fetch("tokenizer", "unicode") == "unicode"

      limit = Integer(analysis.fetch("max_token_bytes", "256"), 10)
      words = term.split.map { |chunk| chunk.gsub(EDGE_PUNCTUATION, "") }.grep_v(/\A_*\z/)
      words if words.all? { |word| NATIVE_WORD.match?(word) && word.bytesize <= limit }
    end

    def quote(term)
      escaped = term.gsub(/["\\_\[\]]/) { |character| "\\#{character}" }
      "\"#{escaped}\""
    end

    def literal(word)
      # Keycap emoji normalize to punctuation that otherwise analyzes to nothing,
      # so the phrase restores the emoji for native analysis.
      return quote("#{word}\uFE0F\u20E3") if ["*", "#"].include?(word)

      quote(word)
    end

    # Prefer a native term-dictionary range, then a wildcard; regex is the last resort.
    def partial(word, match, analysis)
      return literal(word) if ["*", "#"].include?(word)

      pads = (Integer(analysis.fetch("max_token_bytes", "256"), 10) - word.bytesize) / RANGE_PAD.bytesize
      if match == :word_start && pads.positive? && NATIVE_WORD.match?(word) && analysis.fetch("tokenizer", "unicode") == "unicode"
        return "#{word} TO #{word}#{RANGE_PAD * pads}"
      end
      if WILDCARD_UNSAFE.match?(word)
        prefix = match == :word_start ? "" : ".*"
        suffix = match == :word_end ? "" : ".*"
        return "MATCHES #{prefix}#{Regexp.escape(word)}#{suffix}"
      end

      prefix = match == :word_start ? "" : "*"
      suffix = match == :word_end ? "" : "*"
      # CONTAINS keeps uppercase words literal; TIN folds wildcard patterns natively.
      pattern = "#{prefix}#{word}#{suffix}"
      word == word.downcase ? pattern : "CONTAINS #{pattern}"
    end

    def fuzzy(word, distance, prefix, analysis)
      if /[()\[\]"~^]/.match?(word)
        raise NotImplementedError, "Native TIN fuzzy syntax cannot represent this token; use misspellings: false for tokens containing parentheses, brackets, quotes, tildes, or carets"
      end

      # Native analysis turns keycap emoji into these dictionary symbols.
      folded_keycap = ["*", "#"].include?(word) && analysis.fetch("accent_folding", "fold") == "fold"
      surface = folded_keycap ? "#{word}\uFE0F\u20E3" : word
      surface = "CONTAINS #{surface}" if surface != surface.downcase
      "#{surface}~#{prefix}:#{distance}"
    end

    def fuzzy_settings(options)
      return if options == false

      options = { transpositions: false } if options == true
      raise ArgumentError, "Misspellings must be true, false, or an options hash" unless options.is_a?(Hash)

      if options.key?(:max_expansions)
        raise NotImplementedError, "Elasticsearch max_expansions caps are not supported by native TIN; omit max_expansions to use native fuzzy matching"
      end
      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      prefix = options.fetch(:prefix_length, 0)
      transpositions = options.fetch(:transpositions, false)
      unless distance.is_a?(Integer) && distance >= 0 && prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Misspellings distance and prefix_length must be nonnegative integers"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end
      if transpositions
        raise NotImplementedError, "Transposition edit matching is not supported by native TIN fuzzy search; omit transpositions or set transpositions: false for native Levenshtein distance"
      end

      [distance, prefix]
    end
  end
end
