# frozen_string_literal: true

require_relative "regex_automaton"

module Tinkick
  # Raw Searchkick regexp strings use Lucene's ALL syntax and whole-value matching.
  class LucenePattern
    MAX_INTEGER = 2_147_483_647
    MAX_NESTING = 256

    def initialize(source)
      @work = RegexAutomaton::Work.new
      @work.consume(source.length)
      @characters = source.chars
      @position = 0
      @depth = 0
    end

    def compile
      return RegexAutomaton.epsilon(work: @work) if @characters.empty?

      result = union
      raise InvalidQueryError, "Unexpected regular expression character at position #{@position}" if peek

      automaton(result)
    end

    private

    def union
      result = intersection
      result = automaton(result).union(automaton(intersection)) while consume("|")
      result
    end

    def intersection
      result = sequence
      result = automaton(result).intersection(automaton(sequence)) while consume("&")
      result
    end

    def sequence
      parts = [repetition] #: Array[expression]
      while peek && ![")", "|", "&"].include?(peek)
        following = repetition
        previous = parts.last
        if previous.is_a?(String) && following.is_a?(String)
          previous << following
        else
          parts << following
        end
      end
      result = parts.fetch(0)
      parts.drop(1).each { |part| result = automaton(result).concatenate(automaton(part)) }
      result
    end

    def repetition
      result = complement
      loop do
        if consume("?")
          result = automaton(result).union(RegexAutomaton.epsilon(work: @work))
        elsif consume("*")
          result = automaton(result).repeat
        elsif consume("+")
          result = automaton(result).bounds(1, nil)
        elsif consume("{")
          lower = integer
          upper = if consume(",")
            peek == "}" ? nil : integer
          else
            lower
          end
          expect("}")
          result = automaton(result).bounds(lower, upper)
        else
          break
        end
      end
      result
    end

    def complement
      count = 0
      count += 1 while consume("~")
      result = atom
      count.odd? ? automaton(result).complement : result
    end

    def atom
      if consume("[")
        negative = consume("^")
        result = class_part
        result = result.union(class_part) while peek && peek != "]"
        expect("]")
        negative ? RegexAutomaton.any(work: @work).intersection(result.complement) : result
      elsif consume('"')
        result = +""
        result << take while peek && peek != '"'
        expect('"')
        result
      elsif consume("(")
        return +"" if consume(")")

        @depth += 1
        if @depth > MAX_NESTING
          raise InvalidQueryError, "Regular expression nesting exceeds the adapter nesting budget"
        end
        result = union
        expect(")")
        @depth -= 1
        result
      elsif consume(".")
        RegexAutomaton.any(work: @work)
      elsif consume("@")
        RegexAutomaton.all(work: @work)
      elsif consume("#")
        RegexAutomaton.empty(work: @work)
      elsif consume("<")
        interval
      else
        predefined || character
      end
    end

    def class_part
      special = predefined
      return automaton(special) if special

      first = character.ord
      last = consume("-") ? character.ord : first
      RegexAutomaton.characters(first, last, work: @work)
    end

    def predefined
      return unless consume("\\")

      value = peek
      return take if value == "\\"

      groups = {
        "d" => [[48, 57]],
        "s" => [[9, 10], [13, 13], [32, 32]],
        "w" => [[48, 57], [65, 90], [95, 95], [97, 122]],
      } #: Hash[String, Array[[Integer, Integer]]]
      if value && groups.key?(value.downcase)
        take
        result = RegexAutomaton.empty(work: @work)
        groups.fetch(value.downcase).each do |lower, upper|
          result = result.union(RegexAutomaton.characters(lower, upper, work: @work))
        end
        value == value.downcase ? result : RegexAutomaton.any(work: @work).intersection(result.complement)
      elsif value && /[a-zA-Z]/.match?(value)
        raise InvalidQueryError, "Invalid regular expression escape \\#{value}"
      end
    end

    def character
      consume("\\")
      take
    end

    def interval
      value = +""
      value << take while peek && peek != ">"
      expect(">")
      unless value.include?("-")
        raise InvalidQueryError, "Named regular expression automaton #{value.inspect} is not defined"
      end
      match = /\A([+]?\p{Nd}+)-([+]?\p{Nd}+)\z/.match(value)
      raise InvalidQueryError, "Invalid regular expression decimal interval" unless match

      first, last = match[1] || "", match[2] || ""
      lower, upper = decimal(first), decimal(last)
      width = first.length == last.length ? first.length : 0
      RegexAutomaton.interval(lower, upper, width, work: @work)
    end

    def decimal(value)
      result = 0
      value.delete_prefix("+").each_codepoint do |point|
        # Integer.parseInt accepts BMP decimal digits, not surrogate pairs.
        if point > 65_535
          raise InvalidQueryError, "Invalid regular expression decimal interval"
        end
        first = point
        first -= 1 while first.positive? && /\p{Nd}/.match?((first - 1).chr(Encoding::UTF_8))
        result = result * 10 + (point - first) % 10
        if result > MAX_INTEGER
          raise InvalidQueryError, "Regular expression decimal interval exceeds a 32-bit integer"
        end
      end
      result
    end

    def integer
      digits = +""
      digits << take while peek&.match?(/[0-9]/)
      raise InvalidQueryError, "Regular expression repetition requires an integer" if digits.empty?

      value = digits.to_i
      if value > MAX_INTEGER
        raise InvalidQueryError, "Regular expression repetition exceeds a 32-bit integer"
      end
      value
    end

    def automaton(expression)
      expression.is_a?(String) ? RegexAutomaton.literal(expression, work: @work) : expression
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
      raise InvalidQueryError, "Expected #{value.inspect} in regular expression at position #{@position}" unless consume(value)
    end
  end
end
