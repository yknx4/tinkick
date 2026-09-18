# frozen_string_literal: true

module Tinkick
  # Serializes explicit TINQL expressions; PostgreSQL owns parsing and execution.
  class Tinql
    OPTIONS = {
      raw: nil, and: nil, or: nil, and_not: nil,
      near: [:distance], then: [:distance], within: [:words], phrase: [:slop],
      term: nil, all: nil, wildcard: nil, matches: nil, range: nil,
      fuzzy: [:distance, :prefix], boost: [:factor],
      any_of: nil, all_of: nil, at_least: [:count, :percent],
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
      when :term
        literal(string(value))
      when :all
        raise ArgumentError, "tinql all requires true" unless value == true

        "*"
      when :wildcard
        "CONTAINS #{token(value)}"
      when :matches
        pattern = string(value)
        if pattern.gsub(/\\./m, "").match?(/\s/)
          raise ArgumentError, "tinql matches requires a native pattern with escaped whitespace"
        end
        "MATCHES #{pattern}"
      when :range
        bounds = list(value)
        raise ArgumentError, "tinql range requires two bounds; use nil for an open bound" unless bounds.length == 2

        bounds.map { |bound| bound.nil? ? "*" : token(bound) }.join(" TO ")
      when :fuzzy
        "CONTAINS #{token(value)}~#{integer(expression.fetch(:prefix, 1))}:#{integer(expression.fetch(:distance, 1))}"
      when :boost
        factor = expression[:factor]
        unless (factor.is_a?(Integer) || factor.is_a?(Float)) && factor.finite? && factor.between?(0, 10_000)
          raise ArgumentError, "tinql boost factor must be a finite number between 0 and 10000"
        end
        "(#{compile(value)})^#{factor}"
      when :any_of, :all_of, :at_least
        alternatives = list(value).map { |item| "(#{compile(item)})" }.join(" ")
        prefix = if operator == :at_least
          minimum_match(expression)
        elsif operator == :all_of
          "ALL OF "
        else
          ""
        end
        "#{prefix}[#{alternatives}]"
      when :near, :then
        operands = list(value)
        raise ArgumentError, "tinql #{operator} requires two expressions" unless operands.length == 2

        gap = integer(expression[:distance])
        "(#{compile(operands.fetch(0))}) #{operator.to_s.upcase}/#{gap} (#{compile(operands.fetch(1))})"
      when :within
        "(#{compile(value)}) WITHIN #{integer(expression[:words], minimum: 1)}"
      when :phrase
        text = if value.is_a?(String)
          literal(value)
        else
          parts = list(value).map { |part| phrase_part(part) }
          "\"#{parts.join(' ')}\""
        end
        expression.key?(:slop) ? "#{text}~#{integer(expression[:slop])}" : text
      when :and, :or, :and_not
        operands = list(value)
        if operator == :and_not && operands.length != 2
          raise ArgumentError, "tinql and_not requires two expressions"
        end
        separator = { and: " AND ", or: " OR ", and_not: " AND NOT " }.fetch(operator)
        operands.map { |operand| "(#{compile(operand)})" }.join(separator)
      else
        raise ArgumentError, "Unknown tinql operator: #{operator.inspect}"
      end
    end

    private

    def minimum_match(expression)
      if expression.key?(:count) == expression.key?(:percent)
        raise ArgumentError, "tinql at_least requires exactly one of count or percent"
      end
      return "AT LEAST #{integer(expression[:count], minimum: 1)} OF " if expression.key?(:count)

      percent = integer(expression[:percent], minimum: 1)
      raise ArgumentError, "tinql percent cannot exceed 100" if percent > 100

      "AT LEAST #{percent}% OF "
    end

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
