# frozen_string_literal: true

require "active_record"
require "json"

module Tinkick
  class Highlighter
    def initialize(connection)
      @connection = connection
    end

    def highlight(text, query, tag: "<em>", encoder: "default")
      highlight_many([text], query, tag: tag, encoder: encoder).first
    end

    def highlight_many(texts, query, tag: "<em>", encoder: "default")
      raise ArgumentError, "encoder must be default or html" unless ["default", "html"].include?(encoder)
      return Array.new(texts.length) if texts.all?(&:nil?) || query.empty? || query == "*"

      # Mark spans separately so source HTML and caller tags retain distinct
      # encoding, and TIN does not expand placeholders inside caller tags.
      marker = "\u0001tinkick"
      marker += "x" while texts.any? { |text| text&.include?(marker) }
      opening = "#{marker}start\u0002"
      closing = "#{marker}end\u0002"
      end_tag = tag.gsub(/\A<(\w+).+/, "</\\1>")
      mark_many(texts, query, opening, closing).map do |marked|
        next unless marked&.include?(opening)

        encoded = encoder == "html" ? encode_html(marked) : marked
        encoded.gsub(opening) { tag }.gsub(closing) { end_tag }
      end
    end

    private

    def mark_many(texts, query, opening, closing)
      binds = [JSON.generate(texts), opening, closing, query].map do |value|
        ActiveRecord::Relation::QueryAttribute.new("highlight", value, ActiveRecord::Type::String.new)
      end
      # @type var values: Array[String?]
      values = @connection.select_values(<<~SQL, "Tinkick Highlight", binds)
        SELECT tin.highlight(input.text, $2, $3, $4)
        FROM pg_extension
        CROSS JOIN LATERAL jsonb_array_elements_text($1::jsonb) WITH ORDINALITY AS input(text, position)
        WHERE extname = 'tin'
        ORDER BY input.position
      SQL
      values
    end

    def encode_html(text)
      entities = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#x27;", "/" => "&#x2F;" }
      text.gsub(/[&<>"'\/]/) { |character| entities.fetch(character) }
    end
  end
end
