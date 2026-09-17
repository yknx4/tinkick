# frozen_string_literal: true

require_relative "extensions"
require "json"

module Tinkick
  class TextMatch
    def initialize(model)
      @model = model
    end

    def highlight_matches(texts, term, match:, misspellings: false)
      return Array.new(texts.length) if texts.all?(&:nil?)

      sql, binds = if match == :exact
        ['tinkick_input.text COLLATE "C" = ? COLLATE "C"', [term]]
      else
        predicate("tinkick_input.text", term, match: match, misspellings: misspellings)
      end
      @model.with_connection do |connection|
        # @type var values: Array[String?]
        values = connection.select_values(Arel.sql(<<~SQL, *binds, JSON.generate(texts)), "Tinkick Text Highlight")
          SELECT CASE WHEN #{sql} THEN tinkick_input.text ELSE NULL END
          FROM pg_catalog.pg_extension
          CROSS JOIN LATERAL jsonb_array_elements_text(?::jsonb) WITH ORDINALITY AS tinkick_input(text, position)
          WHERE extname = 'tin'
          ORDER BY tinkick_input.position
        SQL
        values
      end
    end

    def predicate(column_sql, term, match:, misspellings: false)
      unless [:text_start, :text_middle, :text_end].include?(match)
        raise ArgumentError, "Unsupported whole-field match mode: #{match.inspect}"
      end
      validate_misspellings!(misspellings)
      return ["FALSE", []] if term.empty?

      options = @model.tinkick_options
      case_sensitive = options && options[:case_sensitive] == true
      function = nil #: String?
      unless options && options[:special_characters] == false
        schema = Extensions.require!(@model, "unaccent")
        function = @model.with_connection { |connection| "#{connection.quote_column_name(schema)}.unaccent" }
      end
      source = normalize_sql(column_sql, !!case_sensitive, function)
      query = normalize_sql("?", !!case_sensitive, function)
      normalized = @model.with_connection { |connection| connection.select_value(Arel.sql("SELECT #{query}", term)) } #: String
      return ["FALSE", []] if normalized.empty?

      @model.logger&.warn("Tinkick: #{match} uses whole-field SQL normalization and can scan rows outside TIN. Prefer word_start, word_middle, or word_end when token matching is suitable; inspect EXPLAIN for this query.")
      pattern = @model.sanitize_sql_like(normalized)
      pattern = "%#{pattern}" unless match == :text_start
      pattern = "#{pattern}%" unless match == :text_end
      ["#{source} COLLATE \"C\" LIKE ?", [pattern]]
    end

    private

    def normalize_sql(expression, case_sensitive, function)
      sql = "(#{expression})::text"
      sql = "lower(#{sql})" unless case_sensitive
      function ? "#{function}(#{sql})" : sql
    end

    def validate_misspellings!(options)
      return if options == false

      options = { transpositions: false } if options == true
      raise ArgumentError, "Misspellings must be true, false, or an options hash" unless options.is_a?(Hash)

      if options.key?(:max_expansions)
        raise NotImplementedError, "Elasticsearch max_expansions caps are not supported by native TIN"
      end
      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      prefix = options.fetch(:prefix_length, 0)
      transpositions = options.fetch(:transpositions, false)
      unless distance.is_a?(Integer) && [0, 1, 2].include?(distance) && prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Whole-field matching requires edit_distance: 0, 1, or 2 and nonnegative prefix_length"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end

      if distance.positive? || transpositions
        raise NotImplementedError, "Fuzzy whole-field matching is not supported by native TIN; use misspellings: false for PostgreSQL prefix, substring, or suffix matching"
      end
    end
  end
end
