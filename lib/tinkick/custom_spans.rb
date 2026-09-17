# frozen_string_literal: true

require "active_record"
require "json"
require_relative "word_match"

module Tinkick
  class CustomSpans
    def initialize(connection)
      @connection = connection
    end

    def locate(texts, tokens:, analysis:)
      spans = Array.new(texts.length) { [] } #: Array[Array[[Integer, Integer]]]
      tokens = tokens.reject(&:empty?).uniq
      return spans if tokens.empty? || texts.all?(&:nil?)

      analysis = configuration(analysis)
      @connection.logger&.warn("Tinkick: custom-analysis highlighting verifies source spans with additional page-text analysis queries. Work grows with page text and eligible tokens; inspect EXPLAIN ANALYZE for large highlights.")
      page_tokens = analyze_many(texts, analysis, check_long: true)
      if analysis.fetch("tokenizer") == "whitespace"
        whitespace_spans(texts, tokens, analysis, page_tokens, spans)
      else
        candidates = native_candidates(texts, tokens)
        analyzed = analyze_many(candidates.map { |_position, _start, _finish, text, _token| text }, analysis)
        mixed = [] #: Array[[[Integer, Integer, Integer, String, String], Array[String]]]
        candidates.each_with_index do |(position, start, finish, _text, token), index|
          words = analyzed.fetch(index)
          if words.any? && words.all? { |word| word == token }
            spans.fetch(position) << [start, finish]
          elsif words.include?(token)
            mixed << [candidates.fetch(index), words]
          end
        end
        subdivide_spans(mixed, analysis, spans)
      end
      spans.map { |values| merge_spans(values) }
    end

    private

    def configuration(analysis)
      defaults = WordMatch::ANALYSIS_DEFAULTS
      raise ArgumentError, "Unknown TIN analysis options" unless (analysis.keys - defaults.keys).empty?

      values = defaults.merge(analysis)
      unless ["unicode", "whitespace"].include?(values.fetch("tokenizer"))
        raise ArgumentError, "Custom source-span mapping requires unicode or whitespace tokenization"
      end
      unless values.fetch("long_tokens") == "split" && values.fetch("max_token_bytes") == "256" && values.fetch("graphemes") == "emoji"
        raise ArgumentError, "Custom source-span mapping for changed token lengths or grapheme policies is not implemented yet"
      end
      values
    end

    def analyze_many(texts, analysis, check_long: false)
      return [] if texts.empty?

      options = tokenizer_options(analysis)
      wider = tokenizer_options(analysis.merge("max_token_bytes" => "2692"))
      arrays = "ARRAY(SELECT tin.tokenize(input.text#{options}))"
      arrays += ", ARRAY(SELECT tin.tokenize(input.text#{wider}))" if check_long
      bind = ActiveRecord::Relation::QueryAttribute.new("texts", JSON.generate(texts), ActiveRecord::Type::String.new)
      values = @connection.select_values(<<~SQL, "Tinkick Custom Span Analysis", [bind])
        SELECT json_build_array(#{arrays})::text
        FROM pg_catalog.pg_extension
        CROSS JOIN LATERAL jsonb_array_elements_text($1::jsonb) WITH ORDINALITY AS input(text, position)
        WHERE extname = 'tin'
        ORDER BY input.position
      SQL
      values.map do |value|
        lists = JSON.parse(value.to_s) #: Array[Array[String]]
        if check_long && lists.fetch(0) != lists.fetch(1)
          raise ArgumentError, "Source-span mapping for split long tokens is not implemented yet"
        end
        lists.fetch(0)
      end
    end

    def tokenizer_options(analysis)
      analysis.map do |name, value|
        argument = name == "max_token_bytes" ? Integer(value, 10) : value
        ", #{name} => #{@connection.quote(argument)}"
      end.join
    end

    def subdivide_spans(mixed, analysis, spans)
      return if mixed.empty?

      # Native highlighting can merge adjacent emoji with the same folded token.
      # Split only when native analysis proves the graphemes reconstruct the
      # complete custom token stream; this is not a general word segmenter.
      parts = [] #: Array[[Integer, [Integer, Integer, Integer, String, String]]]
      mixed.each_with_index do |((position, start, _finish, text, token), _words), index|
        offset = start
        text.grapheme_clusters.each do |grapheme|
          parts << [index, [position, offset, offset + grapheme.length, grapheme, token]]
          offset += grapheme.length
        end
      end
      analyzed = analyze_many(parts.map { |_index, part| part.fetch(3) }, analysis)
      reconstructed = Array.new(mixed.length) { [] } #: Array[Array[String]]
      parts.each_with_index do |(index, (position, start, finish, _text, token)), part_index|
        words = analyzed.fetch(part_index)
        reconstructed.fetch(index).concat(words)
        spans.fetch(position) << [start, finish] if words == [token]
      end
      unless reconstructed == mixed.map(&:last) && analyzed.all? { |words| words.length <= 1 }
        raise ArgumentError, "Source-span mapping for merged tokens with different custom analysis is not implemented yet"
      end
    end

    def whitespace_spans(texts, tokens, analysis, page_tokens, spans)
      candidates = [] #: Array[[Integer, Integer, Integer, String, String]]
      texts.each_with_index do |text, position|
        next unless text

        text.scan(/[^\p{White_Space}]+/) do
          match = Regexp.last_match
          raise ArgumentError, "Unable to locate whitespace source span" unless match

          candidates << [position, match.begin(0).to_i, match.end(0).to_i, match[0].to_s, ""]
        end
      end
      analyzed = analyze_many(candidates.map { |_position, _start, _finish, text, _token| text }, analysis)
      reconstructed = Array.new(texts.length) { [] } #: Array[Array[String]]
      candidates.each_with_index do |(position, start, finish, _text, _token), index|
        words = analyzed.fetch(index)
        reconstructed.fetch(position).concat(words)
        if words.length > 1
          raise ArgumentError, "Source-span mapping for subdivided whitespace tokens is not implemented yet"
        end
        spans.fetch(position) << [start, finish] if words.any? && tokens.include?(words.fetch(0))
      end
      unless reconstructed == page_tokens
        raise ArgumentError, "Whitespace source-span boundaries differ from native TIN tokenization"
      end
    end

    def native_candidates(texts, tokens)
      marker = "\u0001tinkick"
      marker += "x" while texts.any? { |text| text&.include?(marker) }
      opening = "#{marker}start\u0002"
      closing = "#{marker}end\u0002"
      queries = tokens.map do |token|
        if ["*", "#"].include?(token)
          "MATCHES #{Regexp.escape(token)}"
        else
          escaped = token.gsub(/["\\_\[\]]/) { |character| "\\#{character}" }
          "\"#{escaped}\""
        end
      end
      binds = [JSON.generate(texts), JSON.generate(queries), opening, closing].map do |value|
        ActiveRecord::Relation::QueryAttribute.new("highlight", value, ActiveRecord::Type::String.new)
      end
      rows = @connection.select_rows(<<~SQL, "Tinkick Custom Span Candidates", binds)
        SELECT input.position, query.position, tin.highlight(input.text, $3, $4, query.text)
        FROM pg_catalog.pg_extension
        CROSS JOIN LATERAL jsonb_array_elements_text($1::jsonb) WITH ORDINALITY AS input(text, position)
        CROSS JOIN LATERAL jsonb_array_elements_text($2::jsonb) WITH ORDINALITY AS query(text, position)
        WHERE extname = 'tin' AND input.text IS NOT NULL
        ORDER BY input.position, query.position
      SQL
      candidates = [] #: Array[[Integer, Integer, Integer, String, String]]
      rows.each do |row|
        next if row.fetch(2).nil?

        position = row.fetch(0).to_i - 1
        token = tokens.fetch(row.fetch(1).to_i - 1)
        marked = row.fetch(2).to_s
        unless marked.gsub(opening, "").gsub(closing, "") == texts.fetch(position)
          raise ArgumentError, "Native highlighting changed the original source during span mapping"
        end
        marked_spans(marked, opening, closing).each do |start, finish, text|
          candidates << [position, start, finish, text, token]
        end
      end
      candidates
    end

    def marked_spans(marked, opening, closing)
      spans = [] #: Array[[Integer, Integer, String]]
      cursor = 0
      offset = 0
      while (first = marked.index(opening, cursor))
        offset += first - cursor
        last = marked.index(closing, first + opening.length)
        raise ArgumentError, "Native highlighting returned an incomplete source span" unless last

        text = marked[(first + opening.length)...last].to_s
        spans << [offset, offset + text.length, text]
        offset += text.length
        cursor = last + closing.length
      end
      spans
    end

    def merge_spans(spans)
      merged = [] #: Array[[Integer, Integer]]
      spans.sort.each do |start, finish|
        previous = merged.last
        if previous && start <= previous.last
          previous[1] = [previous.last, finish].max
        else
          merged << [start, finish]
        end
      end
      merged
    end
  end
end
