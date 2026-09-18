# frozen_string_literal: true

module Tinkick
  # Serializes explicit TINQL expressions; PostgreSQL owns parsing and execution.
  class Tinql
    OPTIONS = {
      raw: nil, and: nil, or: nil, and_not: nil,
      near: [:distance], then: [:distance], within: [:words], phrase: [:slop],
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
