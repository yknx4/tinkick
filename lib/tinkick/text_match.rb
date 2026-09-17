# frozen_string_literal: true

require_relative "extensions"
require_relative "functions"
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
      distance, prefix, transpositions = fuzzy_settings(misspellings)
      return ["FALSE", []] if term.empty?

      schema = Extensions.require!(@model, "unaccent")
      function = @model.with_connection { |connection| "#{connection.quote_column_name(schema)}.unaccent" }
      normalized = @model.with_connection { |connection| connection.select_value(Arel.sql("SELECT #{function}(lower(?))", term)) } #: String
      return ["FALSE", []] unless normalized.length.between?(1, 50 + distance)

      @model.logger&.warn("Tinkick: #{match} uses whole-field SQL normalization and can scan rows outside TIN. Prefer word_start, word_middle, or word_end when token matching is suitable; inspect EXPLAIN for this query.")
      if distance.zero?
        pattern = @model.sanitize_sql_like(normalized)
        pattern = "%#{pattern}" unless match == :text_start
        pattern = "#{pattern}%" unless match == :text_end
        ["#{function}(lower(#{column_sql})) LIKE ?", [pattern]]
      elsif distance == 1
        pattern = fuzzy_pattern(normalized, match, prefix, transpositions)
        pattern ? ["#{function}(lower(#{column_sql})) ~ ?", [pattern]] : ["FALSE", []]
      else
        distance_predicate("#{function}(lower(#{column_sql}))", normalized, match, prefix, transpositions)
      end
    end

    private

    def distance_predicate(column_sql, term, match, prefix, transpositions)
      function = if transpositions
        Functions.require!(@model)
      else
        schema = Extensions.require!(@model, "fuzzystrmatch")
        @model.with_connection { |connection| "#{connection.quote_column_name(schema)}.levenshtein_less_equal" }
      end
      minimum = [1, term.length - 2].max
      maximum = [50, term.length + 2].min
      characters = term.chars
      fixed = [prefix, term.length].min
      positions = if match == :text_middle
        "CROSS JOIN LATERAL generate_series(1, char_length(tinkick_text.value) - tinkick_lengths.length + 1) AS tinkick_offsets(position)"
      else
        ""
      end
      position = case match
      when :text_start then "1"
      when :text_end then "char_length(tinkick_text.value) - tinkick_lengths.length + 1"
      else "tinkick_offsets.position"
      end
      # Keep field normalization outside the candidate loops when PostgreSQL plans this subquery.
      sql = <<~SQL
        EXISTS (
          SELECT 1
          FROM (SELECT #{column_sql} AS value OFFSET 0) AS tinkick_text
          CROSS JOIN LATERAL generate_series(#{minimum}, LEAST(#{maximum}, char_length(tinkick_text.value))) AS tinkick_lengths(length)
          #{positions}
          CROSS JOIN LATERAL (SELECT substring(tinkick_text.value FROM #{position} FOR tinkick_lengths.length) AS value) AS tinkick_grams
          WHERE left(tinkick_grams.value, #{fixed}) COLLATE "C" = ? COLLATE "C"
            AND #{function}(substring(tinkick_grams.value FROM #{fixed + 1}), ?, 2) <= 2
        )
      SQL
      @model.logger&.warn("Tinkick: whole-field edit_distance: 2 enumerates candidate grams and performs edit-distance comparisons for each row. This can be expensive on long fields or large result sets; inspect EXPLAIN before using it at scale.")
      [sql, [characters.first(fixed).join, characters.drop(fixed).join]]
    end

    def fuzzy_pattern(term, match, prefix, transpositions)
      characters = term.chars.map { |character| Regexp.escape(character) }
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

      patterns = alternatives.select do |candidate|
        candidate.length.between?(1, 50)
      end.map(&:join).uniq
      return if patterns.empty?

      leading = match == :text_start ? "\\A" : ""
      trailing = match == :text_end ? "\\Z" : ""
      "#{leading}(#{patterns.join('|')})#{trailing}"
    end

    def fuzzy_settings(options)
      return [0, 0, false] if options == false

      options = { transpositions: true } if options == true
      raise ArgumentError, "Misspellings must be true, false, or an options hash" unless options.is_a?(Hash)

      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      prefix = options.fetch(:prefix_length, 0)
      transpositions = options.fetch(:transpositions, true)
      unless distance.is_a?(Integer) && [0, 1, 2].include?(distance) && prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Whole-field matching requires edit_distance: 0, 1, or 2 and nonnegative prefix_length"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end

      [distance, prefix, transpositions]
    end
  end
end
