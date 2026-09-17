# frozen_string_literal: true

module Tinkick
  # Searchkick sends Ruby Regexp sources to Lucene with optional syntax disabled.
  # Translate that language, rather than executing Ruby or PostgreSQL extensions.
  class RegexPattern
    def initialize(value)
      source = value.source
      source = source.start_with?("\\A") ? source.delete_prefix("\\A") : ".*#{source}"
      source = source.end_with?("\\z") ? source.delete_suffix("\\z") : "#{source}.*"
      @characters = source.chars
      @position = 0
      @casefold = value.casefold?
    end

    def compile
      expression = @characters.empty? ? "" : union
      raise InvalidQueryError, "Invalid regular expression near position #{@position}" if peek

      "\\A(?:#{expression})\\Z"
    end

    private

    def union
      alternatives = [sequence]
      alternatives << sequence while consume("|")
      "(?:#{alternatives.join("|")})"
    end

    def sequence
      parts = [repetition]
      parts << repetition while peek && !["|", ")"].include?(peek)
      parts.join
    end

    def repetition
      expression = atom
      loop do
        if consume("?")
          expression = "(?:#{expression})?"
        elsif consume("*")
          expression = "(?:#{expression})*"
        elsif consume("+")
          expression = "(?:#{expression})+"
        elsif consume("{")
          lower = integer
          upper = if consume(",")
            peek == "}" ? nil : integer
          else
            lower
          end
          expect("}")
          raise InvalidQueryError, "Regular expression repetition bounds are reversed" if upper && upper < lower

          tail = if upper
            optional_repeat(expression, upper - lower)
          else
            "(?:#{expression})*"
          end
          expression = exact_repeat(expression, lower) + tail
        else
          break
        end
      end
      expression
    end

    def atom
      if consume("(")
        return "" if consume(")")

        expression = union
        expect(")")
        expression
      elsif consume("[")
        negated = consume("^")
        parts = [class_part]
        parts << class_part while peek && peek != "]"
        expect("]")
        expression = "(?:#{parts.join("|")})"
        negated ? "(?!#{expression})." : expression
      elsif consume('"')
        parts = [] #: Array[String]
        parts << literal(take) while peek && peek != '"'
        expect('"')
        parts.join
      elsif consume(".")
        "."
      else
        predefined || literal(character)
      end
    end

    def class_part
      special = predefined
      return special if special

      first = character
      if consume("-")
        last = character
        raise InvalidQueryError, "Regular expression character range is reversed" if first.ord > last.ord

        # Lucene folds individual characters, but does not fold character ranges.
        "[#{codepoint(first)}-#{codepoint(last)}]"
      else
        literal(first)
      end
    end

    def predefined
      return unless consume("\\")

      value = peek
      classes = { "d" => "0-9", "s" => " \\u0009\\u000a\\u000d", "w" => "a-zA-Z_0-9" }
      if value && classes.key?(value.downcase)
        take
        "[#{value == value.upcase ? "^" : ""}#{classes.fetch(value.downcase)}]"
      elsif value && /[a-zA-Z]/.match?(value)
        raise InvalidQueryError, "Lucene does not accept the regular expression escape \\#{value}"
      else
        literal(take)
      end
    end

    def character
      consume("\\")
      take
    end

    def literal(value)
      if @casefold && /[a-zA-Z]/.match?(value)
        "[#{value.downcase}#{value.upcase}]"
      else
        codepoint(value)
      end
    end

    def codepoint(value)
      number = value.ord
      number <= 65_535 ? "\\u#{number.to_s(16).rjust(4, "0")}" : "\\U#{number.to_s(16).rjust(8, "0")}"
    end

    def integer
      digits = +""
      digits << take while peek&.match?(/[0-9]/)
      raise InvalidQueryError, "Regular expression repetition requires an integer" if digits.empty?

      value = digits.to_i
      raise InvalidQueryError, "Regular expression repetition exceeds a 32-bit integer" if value > 2_147_483_647

      value
    end

    # PostgreSQL limits each repetition bound to 255. Nested chunks retain the
    # accepted language without expanding a large number of literal copies.
    def exact_repeat(expression, count)
      return "" if count.zero?
      return "(?:#{expression}){#{count}}" if count <= 255

      groups, remaining = count.divmod(255)
      exact_repeat("(?:#{expression}){255}", groups) + exact_repeat(expression, remaining)
    end

    def optional_repeat(expression, count)
      return "" if count.zero?
      return "(?:#{expression}){0,#{count}}" if count <= 255

      groups, remaining = count.divmod(255)
      exact_repeat("(?:#{expression}){0,255}", groups) + optional_repeat(expression, remaining)
    end

    def peek
      @characters[@position]
    end

    def take
      value = peek
      raise InvalidQueryError, "Unexpected end of regular expression" unless value

      @position += 1
      value
    end

    def consume(value)
      return false unless peek == value

      @position += 1
      true
    end

    def expect(value)
      raise InvalidQueryError, "Expected #{value.inspect} in regular expression" unless consume(value)
    end
  end
end
