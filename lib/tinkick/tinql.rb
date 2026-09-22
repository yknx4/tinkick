# frozen_string_literal: true

require_relative "tinql/expressions"

module Tinkick
  # Serializes explicit TINQL expressions; PostgreSQL owns parsing and execution.
  class Tinql
    include Expressions

    OPTIONS = {
      raw: nil, and: nil, or: nil, and_not: nil,
      near: [:distance], then: [:distance], within: [:words], phrase: [:slop],
      term: nil, all: nil, wildcard: nil, matches: nil, range: nil,
      fuzzy: [:distance, :prefix], boost: [:factor],
      any_of: nil, all_of: nil, at_least: [:count, :percent],
      encloses: nil, not_encloses: nil, enclosed_by: nil, not_enclosed_by: nil,
      overlapping: nil, not_overlapping: nil, before: nil, after: nil,
      in_first: [:words, :percent], in_last: [:words, :percent],
      in_middle: [:percent], in_words: [:from, :to],
    }.freeze

    def compile(expression)
      return literal(expression) if expression.is_a?(String)
      unless expression.is_a?(Hash)
        raise ArgumentError, "tinql requires a literal string or an expression hash with one operator"
      end

      operators = expression.keys & OPTIONS.keys
      raise ArgumentError, "tinql requires exactly one operator" unless operators.length == 1

      operator = operators.fetch(0)
      unknown = expression.keys - [operator, *OPTIONS.fetch(operator)]
      raise ArgumentError, "Unknown tinql options: #{unknown.join(', ')}" unless unknown.empty?

      value = expression.fetch(operator)
      case operator
      when :raw
        string(value)
      when :encloses, :not_encloses, :enclosed_by, :not_enclosed_by,
        :overlapping, :not_overlapping, :before, :after
        compile_span(operator, value)
      when :in_first, :in_last, :in_middle
        "(#{compile(value)}) #{operator.to_s.tr('_', ' ').upcase} #{position_size(expression)}"
      when :in_words
        first = integer(expression[:from])
        last = integer(expression[:to], minimum: first)
        "(#{compile(value)}) IN WORDS #{first} TO #{last}"
      when :term
        literal(string(value))
      when :all
        raise ArgumentError, "tinql all requires true" unless value == true

        "*"
      when :wildcard
        "CONTAINS #{token(value)}"
      when :matches
        compile_pattern(value)
      when :range
        compile_range(value)
      when :fuzzy
        "CONTAINS #{token(value)}~#{integer(expression.fetch(:prefix, 1))}:#{integer(expression.fetch(:distance, 1))}"
      when :boost
        compile_boost(value, expression)
      when :any_of, :all_of, :at_least
        compile_group(operator, value, expression)
      when :near, :then
        compile_proximity(operator, value, expression)
      when :within
        "(#{compile(value)}) WITHIN #{integer(expression[:words], minimum: 1)}"
      when :phrase
        compile_phrase(value, expression)
      when :and, :or, :and_not
        compile_boolean(operator, value)
      else
        raise ArgumentError, "Unknown tinql operator: #{operator.inspect}"
      end
    end

    private

    def token(value)
      text = string(value)
      if text.match?(/[\s()\[\]"~^]/)
        raise ArgumentError, "tinql token patterns and range bounds must be single native terms without delimiters; use raw for explicit syntax"
      end
      text
    end

    def string(value)
      raise ArgumentError, "tinql expects a nonempty string" unless value.is_a?(String) && !value.strip.empty?

      value
    end

    def literal(value)
      escaped = escape(value)
      "\"#{escaped}\""
    end

    def escape(value)
      string(value).gsub(/["\\_\[\]]/) { |character| "\\#{character}" }
    end

    def phrase_part(value)
      return "_" if value.nil?
      return escape(value) if value.is_a?(String)

      "[#{list(value).map { |alternative| escape(alternative) }.join(' ')}]"
    end

    def integer(value, minimum: 0)
      unless value.is_a?(Integer) && value >= minimum
        raise ArgumentError, "tinql expects an integer >= #{minimum}"
      end

      value
    end

    def list(value)
      raise ArgumentError, "tinql expects a nonempty array of expressions" unless value.is_a?(Array) && !value.empty?

      value
    end
  end
end
