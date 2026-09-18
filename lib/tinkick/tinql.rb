# frozen_string_literal: true

module Tinkick
  # Serializes explicit TINQL expressions; PostgreSQL owns parsing and execution.
  class Tinql
    def compile(expression)
      return literal(expression) if expression.is_a?(String)
      unless expression.is_a?(Hash) && expression.length == 1
        raise ArgumentError, "tinql requires a literal string or an expression hash with one operator"
      end

      operator, value = expression.first
      case operator
      when :raw
        string(value)
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
      escaped = string(value).gsub(/["\\_\[\]]/) { |character| "\\#{character}" }
      "\"#{escaped}\""
    end

    def list(value)
      raise ArgumentError, "tinql expects a nonempty array of expressions" unless value.is_a?(Array) && !value.empty?

      value
    end
  end
end
