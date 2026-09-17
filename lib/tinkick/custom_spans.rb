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
      changed_policy = ["long_tokens", "max_token_bytes", "graphemes"].any? do |name|
        analysis.fetch(name) != WordMatch::ANALYSIS_DEFAULTS.fetch(name)
      end
      rows = analysis_rows(texts, analysis, check_long: !changed_policy)
      page_tokens = rows.map { |row| row.fetch(0) }
      if changed_policy || rows.any? { |row| row.first != row.last }
        policy_spans(texts, tokens, analysis, page_tokens, spans)
      elsif analysis.fetch("tokenizer") == "whitespace"
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
      values
    end

    def analyze_many(texts, analysis)
      analysis_rows(texts, analysis).map { |row| row.fetch(0) }
    end

    def analysis_rows(texts, analysis, check_long: false)
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
      values.map { |value| JSON.parse(value.to_s) } #: Array[Array[Array[String]]]
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
      candidates = source_runs(texts)
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

    def source_runs(texts)
      candidates = [] #: Array[[Integer, Integer, Integer, String, String]]
      texts.each_with_index do |text, position|
        next unless text

        text.scan(/[^\p{White_Space}]+/) do
          match = Regexp.last_match
          raise ArgumentError, "Unable to locate whitespace source span" unless match

          candidates << [position, match.begin(0).to_i, match.end(0).to_i, match[0].to_s, ""]
        end
      end
      candidates
    end

    def policy_spans(texts, tokens, analysis, page_tokens, spans)
      @connection.logger&.warn("Tinkick: token-policy highlighting analyzes grapheme prefixes inside matching whitespace runs. A long run can require quadratic tokenization work; inspect EXPLAIN ANALYZE before highlighting large fields with custom token policies.")
      candidates = source_runs(texts)
      analyzed = analyze_many(candidates.map { |_position, _start, _finish, text, _token| text }, analysis)
      reconstructed = Array.new(texts.length) { [] } #: Array[Array[String]]
      selected = [] #: Array[[[Integer, Integer, Integer, String, String], Array[String]]]
      candidates.each_with_index do |candidate, index|
        words = analyzed.fetch(index)
        reconstructed.fetch(candidate.first).concat(words)
        selected << [candidate, words] if words.any? { |word| tokens.include?(word) }
      end
      unless reconstructed == page_tokens
        raise ArgumentError, "Source groups do not reconstruct the full native TIN token stream"
      end
      return if selected.empty?

      inputs = selected.flat_map { |candidate, _words| [candidate.fetch(3), *candidate.fetch(3).grapheme_clusters] }.uniq
      surface_analysis = analysis.merge("tokenizer" => "whitespace", "long_tokens" => "split", "max_token_bytes" => "2692", "graphemes" => "retain")
      normalized = analyze_many(inputs, surface_analysis).map(&:join)
      surfaces = inputs.zip(normalized).to_h
      boundaries = selected.map { |candidate, _words| cumulative_lengths(candidate.fetch(3).grapheme_clusters) }
      prefixes = prefix_counts(selected, boundaries, analysis)
      selected.each_with_index do |((position, start, _finish, text, _token), words), index|
        normalized_parts = text.grapheme_clusters.map { |part| surfaces.fetch(part) }
        surface = surfaces.fetch(text)
        unless normalized_parts.join == surface
          raise ArgumentError, "Native grapheme normalization does not reconstruct the source surface"
        end
        mapped = policy_token_spans(words, boundaries.fetch(index), cumulative_lengths(normalized_parts), surface, prefixes.fetch(index))
        mapped.each_with_index do |(first, last), ordinal|
          spans.fetch(position) << [start + first, start + last] if tokens.include?(words.fetch(ordinal))
        end
      end
    end

    def cumulative_lengths(parts)
      parts.each_with_object([0]) { |part, lengths| lengths << lengths.last.to_i + part.length }
    end

    def prefix_counts(groups, boundaries, analysis)
      input = groups.each_with_index.map do |(candidate, words), index|
        { text: candidate.fetch(3), words: words, ends: boundaries.fetch(index) }
      end
      bind = ActiveRecord::Relation::QueryAttribute.new("groups", JSON.generate(input), ActiveRecord::Type::String.new)
      options = tokenizer_options(analysis)
      # Keep complete prefix token arrays in PostgreSQL. Each returned row holds
      # only its ordinal and two agreement counts, rather than quadratic text.
      rows = @connection.select_rows(<<~SQL, "Tinkick Custom Span Prefixes", [bind])
        WITH sources AS MATERIALIZED (
          SELECT item.position, item.value->>'text' AS text, item.value->'ends' AS ends,
            ARRAY(SELECT jsonb_array_elements_text(item.value->'words')) AS words
          FROM pg_catalog.pg_extension
          CROSS JOIN LATERAL jsonb_array_elements($1::jsonb) WITH ORDINALITY AS item(value, position)
          WHERE extname = 'tin'
        )
        SELECT sources.position, prefix.position, agreement.count,
          agreement.count + CASE WHEN
            left(sources.words[agreement.count + 1], char_length(analyzed.words[agreement.count + 1])) COLLATE "C"
              = analyzed.words[agreement.count + 1] COLLATE "C" THEN 1 ELSE 0 END
        FROM sources
        CROSS JOIN LATERAL jsonb_array_elements_text(sources.ends) WITH ORDINALITY AS prefix(value, position)
        CROSS JOIN LATERAL (
          SELECT ARRAY(SELECT tin.tokenize(left(sources.text, prefix.value::integer)#{options})) AS words OFFSET 0
        ) AS analyzed
        CROSS JOIN LATERAL (
          SELECT COALESCE((
            SELECT number - 1 FROM generate_series(1, cardinality(sources.words)) AS positions(number)
            WHERE analyzed.words[number] COLLATE "C" IS DISTINCT FROM sources.words[number] COLLATE "C"
            ORDER BY number LIMIT 1
          ), cardinality(sources.words)) AS count OFFSET 0
        ) AS agreement
        ORDER BY sources.position, prefix.position
      SQL
      counts = Array.new(groups.length) { [] } #: Array[Array[[Integer, Integer]]]
      rows.each { |row| counts.fetch(row.fetch(0).to_i - 1) << [row.fetch(2).to_i, row.fetch(3).to_i] }
      counts
    end

    def policy_token_spans(words, boundaries, normalized_boundaries, surface, prefixes)
      stable = prefixes.map(&:first)
      (stable.length - 2).downto(0) { |index| stable[index] = [stable.fetch(index), stable.fetch(index + 1)].min }
      cursor = 0
      words.each_with_index.map do |word, ordinal|
        finish = stable.index { |count| count > ordinal }
        raise ArgumentError, "Native token prefix never reached its final form" unless finish

        start = (0...finish).reverse_each.find { |index| prefixes.fetch(index).last <= ordinal } || 0
        first = surface.index(word, [normalized_boundaries.fetch(start), cursor].max)
        unless first && first + word.length <= normalized_boundaries.fetch(finish)
          raise ArgumentError, "Native token could not be aligned with its normalized source surface"
        end
        cursor = first + word.length
        source_first = normalized_boundaries.index { |offset| offset > first }
        source_last = normalized_boundaries.index { |offset| offset >= cursor }
        raise ArgumentError, "Native token could not be mapped to original graphemes" unless source_first && source_last

        [boundaries.fetch(source_first - 1), boundaries.fetch(source_last)]
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
