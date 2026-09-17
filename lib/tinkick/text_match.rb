# frozen_string_literal: true

require_relative "extensions"

module Tinkick
  class TextMatch
    def initialize(model)
      @model = model
    end

    def predicate(column_sql, term, match:, misspellings: false)
      unless [:text_start, :text_middle, :text_end].include?(match)
        raise ArgumentError, "Unsupported whole-field match mode: #{match.inspect}"
      end
      validate_misspellings(misspellings)
      return ["FALSE", []] if term.empty?

      schema = Extensions.require!(@model, "unaccent")
      function = @model.with_connection { |connection| "#{connection.quote_column_name(schema)}.unaccent" }
      normalized = @model.with_connection { |connection| connection.select_value(Arel.sql("SELECT #{function}(lower(?))", term)) } #: String
      return ["FALSE", []] unless normalized.length.between?(1, 50)

      pattern = @model.sanitize_sql_like(normalized)
      pattern = "%#{pattern}" unless match == :text_start
      pattern = "#{pattern}%" unless match == :text_end
      @model.logger&.warn("Tinkick: #{match} uses whole-field SQL normalization and can scan rows outside TIN. Prefer word_start, word_middle, or word_end when token matching is suitable; inspect EXPLAIN for this query.")
      ["#{function}(lower(#{column_sql})) LIKE ?", [pattern]]
    end

    private

    def validate_misspellings(options)
      return if options == false

      unless options.is_a?(Hash)
        raise ArgumentError, "Whole-field matching currently requires misspellings: false or edit_distance: 0"
      end
      unknown = options.keys - [:transpositions, :edit_distance, :distance, :prefix_length]
      raise ArgumentError, "Unsupported misspellings options: #{unknown.join(', ')}" unless unknown.empty?

      distance = options.fetch(:edit_distance, options.fetch(:distance, 1))
      prefix = options.fetch(:prefix_length, 0)
      transpositions = options.fetch(:transpositions, true)
      unless distance == 0 && prefix.is_a?(Integer) && prefix >= 0
        raise ArgumentError, "Whole-field matching currently requires edit_distance: 0 and nonnegative prefix_length"
      end
      unless transpositions == true || transpositions == false
        raise ArgumentError, "Misspellings transpositions must be true or false"
      end
    end
  end
end
