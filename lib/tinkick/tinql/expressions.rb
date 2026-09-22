# frozen_string_literal: true

require "active_support/concern"

module Tinkick
  class Tinql
    module Expressions
      extend ActiveSupport::Concern

      private

      def compile_span(operator, value)
        # @type self: Tinql
        operands = list(value)
        raise ArgumentError, "tinql #{operator} requires two expressions" unless operands.length == 2

        "(#{compile(operands.fetch(0))}) #{operator.to_s.tr('_', ' ').upcase} (#{compile(operands.fetch(1))})"
      end

      def compile_pattern(value)
        # @type self: Tinql
        pattern = string(value)
        if pattern.gsub(/\./m, "").match?(/\s/)
          raise ArgumentError, "tinql matches requires a native pattern with escaped whitespace"
        end
        "MATCHES #{pattern}"
      end

      def compile_range(value)
        # @type self: Tinql
        bounds = list(value)
        raise ArgumentError, "tinql range requires two bounds; use nil for an open bound" unless bounds.length == 2

        bounds.map { |bound| bound.nil? ? "*" : token(bound) }.join(" TO ")
      end

      def compile_boost(value, expression)
        # @type self: Tinql
        factor = expression[:factor]
        unless (factor.is_a?(Integer) || factor.is_a?(Float)) && factor.finite? && factor.between?(0, 10_000)
          raise ArgumentError, "tinql boost factor must be a finite number between 0 and 10000"
        end
        "(#{compile(value)})^#{factor}"
      end

      def compile_group(operator, value, expression)
        # @type self: Tinql
        alternatives = list(value).map { |item| "(#{compile(item)})" }.join(" ")
        prefix = if operator == :at_least
          minimum_match(expression)
        elsif operator == :all_of
          "ALL OF "
        else
          ""
        end
        "#{prefix}[#{alternatives}]"
      end

      def compile_proximity(operator, value, expression)
        # @type self: Tinql
        operands = list(value)
        raise ArgumentError, "tinql #{operator} requires two expressions" unless operands.length == 2

        gap = integer(expression[:distance])
        "(#{compile(operands.fetch(0))}) #{operator.to_s.upcase}/#{gap} (#{compile(operands.fetch(1))})"
      end

      def compile_phrase(value, expression)
        # @type self: Tinql
        text = if value.is_a?(String)
          literal(value)
        else
          parts = list(value).map { |part| phrase_part(part) }
          "\"#{parts.join(' ')}\""
        end
        expression.key?(:slop) ? "#{text}~#{integer(expression[:slop])}" : text
      end

      def compile_boolean(operator, value)
        # @type self: Tinql
        operands = list(value)
        if operator == :and_not && operands.length != 2
          raise ArgumentError, "tinql and_not requires two expressions"
        end
        separator = { and: " AND ", or: " OR ", and_not: " AND NOT " }.fetch(operator)
        operands.map { |operand| "(#{compile(operand)})" }.join(separator)
      end

      def position_size(expression)
        # @type self: Tinql
        size = quantity(expression, :words, "position")
        expression.key?(:words) ? "#{size} WORDS" : size
      end

      def minimum_match(expression)
        # @type self: Tinql
        "AT LEAST #{quantity(expression, :count, 'at_least')} OF "
      end

      def quantity(expression, option, context)
        # @type self: Tinql
        if expression.key?(option) == expression.key?(:percent)
          raise ArgumentError, "tinql #{context} requires exactly one of #{option} or percent"
        end
        return integer(expression[option], minimum: 1).to_s if expression.key?(option)

        "#{percentage(expression[:percent])}%"
      end

      def percentage(value)
        # @type self: Tinql
        percent = integer(value, minimum: 1)
        raise ArgumentError, "tinql percent cannot exceed 100" if percent > 100

        percent
      end
    end
  end
end
