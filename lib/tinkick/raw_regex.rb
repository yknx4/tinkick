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
      if requires_automaton?(source)
        result = automaton_predicate(column, source)
        @model.logger&.warn("Tinkick: this Lucene regular expression performs a Unicode character walk per candidate value outside TIN. Long values can increase the cost substantially; use selective search/where conditions and inspect EXPLAIN.")
        result
      else
        pattern = RegexPattern.new(source).compile
        @model.logger&.warn("Tinkick: regular expression filters can scan column values outside TIN. Use selective search/where conditions and inspect EXPLAIN; an optional pg_trgm expression index may help suitable patterns.")
        ["(#{column})::text COLLATE \"C\" ~ ?", [pattern]]
      end
    end

    private

    def requires_automaton?(source)
      RegexAutomaton::Work.new.consume(source.length)
      optional = false
      quoted = false
      escaped = false
      in_class = false
      # Before optional ^, after ^, or after the first class member.
      class_position = 0
      depth = 0
      source.each_char do |character|
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
          depth -= 1 if depth.positive?
        elsif ["&", "~", "@", "#", "<"].include?(character)
          optional = true
        end
      end
      optional
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
