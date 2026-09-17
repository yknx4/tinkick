# frozen_string_literal: true

require "json"
require_relative "regex_pattern"
require_relative "lucene_pattern"

module Tinkick
  # The column argument is an adapter-owned quoted SQL expression. User pattern
  # text becomes a bound PostgreSQL pattern or a bound Unicode transition graph.
  class RawRegex
    def initialize(model)
      @model = model
    end

    def predicate(column, source)
      result = native_predicate(column, source, RegexAutomaton::Work.new)
      if result
        @model.logger&.warn("Tinkick: regular expression filters can scan column values outside TIN. Use selective search/where conditions and inspect EXPLAIN; an optional pg_trgm expression index may help suitable patterns.")
        result
      else
        result = automaton_predicate(column, source)
        @model.logger&.warn("Tinkick: this Lucene regular expression performs a Unicode character walk per candidate value outside TIN. Long values can increase the cost substantially; use selective search/where conditions and inspect EXPLAIN.")
        result
      end
    end

    private

    def native_predicate(column, source, work)
      shape = structure(source, work)
      unless shape[:optional]
        return ["(#{column})::text COLLATE \"C\" ~ ?", [RegexPattern.new(source).compile]]
      end

      if !shape[:unions].empty?
        combine(column, source, shape[:unions], "OR", work)
      elsif !shape[:intersections].empty?
        combine(column, source, shape[:intersections], "AND", work)
      elsif source.start_with?("(") && shape[:closing_group] == source.length - 1
        native_predicate(column, source[1...-1] || "", work)
      elsif source.start_with?("~(") && shape[:closing_group] == source.length - 1
        child = native_predicate(column, source[2...-1] || "", work)
        child && ["((#{column}) IS NOT NULL AND NOT (#{child[0]}))", child[1]]
      end
    end

    def combine(column, source, positions, operator, work)
      parts = [] #: Array[String]
      binds = [] #: Array[filter_scalar]
      start = 0
      (positions + [source.length]).each do |position|
        return if start == position

        child = native_predicate(column, source[start...position] || "", work)
        return unless child

        parts << "(#{child[0]})"
        binds.concat(child[1])
        start = position + 1
      end
      ["(#{parts.join(" #{operator} ")})", binds]
    end

    # Only separators outside quoted text, classes, escapes, and groups can
    # combine whole-value SQL predicates. Embedded Boolean syntax stays a DFA.
    def structure(source, work)
      work.consume(source.length)
      optional = false
      unions = [] #: Array[Integer]
      intersections = [] #: Array[Integer]
      closing_group = nil #: Integer?
      quoted = false
      escaped = false
      in_class = false
      # Before optional ^, after ^, or after the first class member.
      class_position = 0
      depth = 0
      source.each_char.with_index do |character, index|
        if quoted
          quoted = false if character == '"'
        elsif escaped
          escaped = false
          class_position = 2
        elsif character == "\\"
          escaped = true
        elsif in_class
          if character == "]" && class_position == 2
            in_class = false
          elsif character == "^" && class_position.zero?
            class_position = 1
          else
            class_position = 2
          end
        elsif character == '"'
          quoted = true
        elsif character == "["
          in_class = true
          class_position = 0
        elsif character == "("
          depth += 1
          if depth > LucenePattern::MAX_NESTING
            raise InvalidQueryError, "Regular expression nesting exceeds the adapter nesting budget"
          end
        elsif character == ")"
          if depth.positive?
            depth -= 1
            closing_group ||= index if depth.zero?
          end
        elsif character == "|"
          unions << index if depth.zero?
        elsif character == "&"
          optional = true
          intersections << index if depth.zero?
        elsif ["~", "#", "<"].include?(character)
          optional = true
        end
      end
      { optional: optional, unions: unions, intersections: intersections, closing_group: closing_group }
    end

    def automaton_predicate(column, source)
      automaton = LucenePattern.new(source).compile
      payload = JSON.generate(edges: automaton.edges, accept: automaton.edges.each_index.map { |state| automaton.accepting?(state) })
      sql = <<~SQL.squish
        EXISTS (
          WITH RECURSIVE tinkick_regexp_graph AS (SELECT ?::jsonb AS graph),
          tinkick_regexp_input AS (
            SELECT (#{column})::text AS value, char_length((#{column})::text) AS length
          ),
          tinkick_regexp_run(position, state) AS (
            SELECT 0, 0 FROM tinkick_regexp_input WHERE value IS NOT NULL
            UNION ALL
            SELECT run.position + 1, (edge.value ->> 2)::integer
            FROM tinkick_regexp_run AS run
            CROSS JOIN tinkick_regexp_input AS input
            CROSS JOIN tinkick_regexp_graph AS specification
            CROSS JOIN LATERAL jsonb_array_elements(specification.graph -> 'edges' -> run.state) AS edge(value)
            WHERE run.position < input.length
              AND ascii(substring(input.value FROM run.position + 1 FOR 1))
                BETWEEN (edge.value ->> 0)::integer AND (edge.value ->> 1)::integer
          )
          SELECT 1 FROM tinkick_regexp_run AS run
          CROSS JOIN tinkick_regexp_input AS input
          CROSS JOIN tinkick_regexp_graph AS specification
          WHERE run.position = input.length
            AND specification.graph -> 'accept' -> run.state = 'true'::jsonb
        )
      SQL
      [sql, [payload]]
    end
  end
end
