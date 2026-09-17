# frozen_string_literal: true

require "active_record"

module Tinkick
  class Highlighter
    def initialize(connection)
      @connection = connection
    end

    def highlight(text, query, tag: "<em>", encoder: "default")
      raise ArgumentError, "encoder must be default or html" unless ["default", "html"].include?(encoder)
      return if text.nil? || query.empty? || query == "*"

      # Mark spans separately so source HTML and caller tags retain distinct
      # encoding, and TIN does not expand placeholders inside caller tags.
      marker = "\u0001tinkick"
      marker += "x" while text.include?(marker)
      opening = "#{marker}start\u0002"
      closing = "#{marker}end\u0002"
      marked = mark(text, query, opening, closing)
      return unless marked&.include?(opening)

      encoded = encoder == "html" ? encode_html(marked) : marked
      end_tag = tag.gsub(/\A<(\w+).+/, "</\\1>")
      encoded.gsub(opening) { tag }.gsub(closing) { end_tag }
    end

    private

    def mark(text, query, opening, closing)
      binds = [text, opening, closing, query].map do |value|
        ActiveRecord::Relation::QueryAttribute.new("highlight", value, ActiveRecord::Type::String.new)
      end
      # @type var value: String?
      value = @connection.select_value(
        "SELECT tin.highlight($1, $2, $3, $4) FROM pg_extension WHERE extname = 'tin'",
        "Tinkick Highlight",
        binds,
      )
      value
    end

    def encode_html(text)
      entities = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#x27;", "/" => "&#x2F;" }
      text.gsub(/[&<>"'\/]/) { |character| entities.fetch(character) }
    end
  end
end
