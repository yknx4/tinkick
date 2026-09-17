# frozen_string_literal: true

module Tinkick
  class SourceFilter
    def initialize(selection)
      if selection.is_a?(Hash)
        unless selection.keys.all? { |key| ["includes", "excludes"].include?(key.to_s) }
          raise InvalidQueryError, "select accepts only includes and excludes source filters"
        end
        @includes = patterns(selection[:includes] || selection["includes"])
        @includes = ["*"] if @includes.empty?
        @excludes = patterns(selection[:excludes] || selection["excludes"])
      else
        @includes = patterns(selection)
        @excludes = []
      end
      @included = compile(@includes)
      @excluded = compile(@excludes)
    end

    def columns(definitions)
      definitions.filter_map do |name, column|
        next if matches?(@excluded, name)

        selected = matches?(@included, name)
        descendants = [:json, :jsonb].include?(column.type) && @includes.any? { |pattern| descendant?(pattern, name) }
        name if selected || descendants
      end
    end

    def nested?(definitions)
      columns(definitions).any? do |name|
        [:json, :jsonb].include?(definitions.fetch(name).type) &&
          (!matches?(@included, name) || @excludes.any? { |pattern| descendant?(pattern, name) })
      end
    end

    def call(attributes)
      filter_object(attributes, "")
    end

    private

    def patterns(value)
      values = value.is_a?(Array) ? value : (value.nil? ? [] : [value]) #: Array[String | Symbol]
      values.map do |field|
        unless field.is_a?(String) || field.is_a?(Symbol)
          raise InvalidQueryError, "select source fields must be strings or symbols"
        end
        field.to_s
      end
    end

    def compile(patterns)
      patterns.map { |pattern| Regexp.new("\\A#{Regexp.escape(pattern).gsub('\\*', '.*')}(?:\\..*)?\\z", Regexp::MULTILINE) }
    end

    def matches?(patterns, path)
      patterns.any? { |pattern| pattern.match?(path) }
    end

    # Walk the literal prefix through the glob, keeping '*' transitions alive.
    # A remaining state means some descendant can match, without guessing keys.
    def descendant?(pattern, path)
      states = [0]
      "#{path}.".each_char do |character|
        states = states.flat_map do |index|
          next_states = [] #: Array[Integer]
          while pattern[index] == "*"
            next_states << index
            index += 1
          end
          next_states << index + 1 if pattern[index] == character
          next_states
        end.uniq
        return false if states.empty?
      end
      true
    end

    def filter_object(values, path)
      result = {} #: Hash[String, result_value]
      values.each do |key, value|
        keep, filtered = filter_value(value, path.empty? ? key : "#{path}.#{key}")
        result[key] = filtered if keep
      end
      result
    end

    def filter_value(value, path)
      return [false, nil] if matches?(@excluded, path)

      selected = matches?(@included, path)
      return [true, value] if selected && @excludes.none? { |pattern| descendant?(pattern, path) }

      filtered = case value
      when Hash
        filter_object(value, path)
      when Array
        output = [] #: Array[result_value]
        value.each do |item|
          keep, child = filter_value(item, path)
          keep &&= !child.empty? if child.is_a?(Hash) || child.is_a?(Array)
          output << child if keep
        end
        output
      else
        return [selected, value]
      end
      [selected || !filtered.empty?, filtered]
    end
  end
end
