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
      fragments_many(texts, query, tag: tag, encoder: encoder).map(&:first)
    end

    def whole_fields(texts, tag: "<em>", encoder: "default", fragment_size: 0, number_of_fragments: 5)
      validate_options(encoder, fragment_size, number_of_fragments)
      end_tag = tag.gsub(/\A<(\w+).+/, "</\\1>")
      texts.map do |text|
        next [] if text.nil? || text.empty?

        ["#{tag}#{encoder == 'html' ? encode_html(text) : text}#{end_tag}"]
      end
    end

    def fragments_many(texts, query, tag: "<em>", encoder: "default", fragment_size: 0, number_of_fragments: 5)
      validate_options(encoder, fragment_size, number_of_fragments)
      return Array.new(texts.length) { [] } if texts.all?(&:nil?) || query.empty? || query == "*"

      opening, closing = markers(texts)
      render_marked(mark_many(texts, query, opening, closing), opening, closing,
        tag: tag, encoder: encoder, fragment_size: fragment_size, number_of_fragments: number_of_fragments)
    end

    private

    def markers(texts)
      # Mark spans separately so source HTML and caller tags retain distinct
      # encoding, and TIN does not expand placeholders inside caller tags.
      marker = "\u0001tinkick"
      marker += "x" while texts.any? { |text| text&.include?(marker) }
      ["#{marker}start\u0002", "#{marker}end\u0002"]
    end

    def render_marked(texts, opening, closing, tag:, encoder:, fragment_size:, number_of_fragments:)
      end_tag = tag.gsub(/\A<(\w+).+/, "</\\1>")
      texts.map do |marked|
        next [] unless marked&.include?(opening)

        fragments = if fragment_size.zero? || number_of_fragments.zero?
          [marked]
        else
          snippets(marked, opening, closing, fragment_size, number_of_fragments)
        end
        fragments.map do |fragment|
          encoded = encoder == "html" ? encode_html(fragment) : fragment
          encoded.gsub(opening) { tag }.gsub(closing) { end_tag }
        end
      end
    end

    def validate_options(encoder, fragment_size, number_of_fragments)
      raise ArgumentError, "encoder must be default or html" unless ["default", "html"].include?(encoder)
      unless fragment_size.is_a?(Integer) && fragment_size >= 0
        raise ArgumentError, "fragment_size must be a nonnegative integer"
      end
      unless number_of_fragments.is_a?(Integer) && number_of_fragments >= 0
        raise ArgumentError, "number_of_fragments must be a nonnegative integer"
      end
    end

    def snippets(marked, opening, closing, size, maximum)
      graphemes, spans = fragment_parts(marked, opening, closing)
      # @type var fragments: Array[String]
      fragments = []
      previous_end = 0
      spans.each do |span_start, span_end|
        next if span_end <= previous_end

        first, last = fragment_bounds(graphemes, spans, span_start, span_end, size)
        fragment = render_fragment(graphemes, spans, first, last, opening, closing)
        fragments << fragment unless fragments.include?(fragment)
        previous_end = last
        break if fragments.length >= maximum
      end
      fragments
    end

    def fragment_parts(marked, opening, closing)
      portions = marked.split(opening)
      graphemes = portions.shift.to_s.grapheme_clusters
      # @type var spans: Array[[Integer, Integer]]
      spans = []
      portions.each do |portion|
        match, following = portion.split(closing, 2)
        first = graphemes.length
        graphemes.concat(match.to_s.grapheme_clusters)
        spans << [first, graphemes.length]
        graphemes.concat(following.to_s.grapheme_clusters)
      end
      [graphemes, spans]
    end

    def fragment_bounds(graphemes, spans, span_start, span_end, size)
      context = [size - (span_end - span_start), 0].max
      first = [span_start - (context + 1) / 2, 0].max
      last = [[first + size, span_end].max, graphemes.length].min
      # Approximate word context without cutting a Unicode grapheme or a native
      # match span. A long word or phrase can exceed the requested fragment size.
      first -= 1 while first.positive? && !graphemes.fetch(first - 1).match?(/[[:space:]]/)
      last += 1 while last < graphemes.length && !graphemes.fetch(last).match?(/[[:space:]]/)
      spans.each do |start, finish|
        first = start if start < first && finish > first
        last = finish if start < last && finish > last
      end
      first += 1 while first < span_start && graphemes.fetch(first).match?(/[[:space:]]/)
      last -= 1 while last > span_end && graphemes.fetch(last - 1).match?(/[[:space:]]/)
      [first, last]
    end

    def render_fragment(graphemes, spans, first, last, opening, closing)
      result = +""
      cursor = first
      spans.each do |start, finish|
        next if start < first || start >= last

        result << graphemes.slice(cursor, start - cursor).to_a.join
        result << opening << graphemes.slice(start, finish - start).to_a.join << closing
        cursor = finish
      end
      result << graphemes.slice(cursor, last - cursor).to_a.join
    end

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
