# frozen_string_literal: true

require_relative "highlighter"

module Tinkick
  class Highlights
    attr_reader :fields

    def initialize(query, options)
      @query = query
      defaults = {} #: highlight_configuration
      settings = options == true ? defaults : options
      raise ArgumentError, "highlight must be true, false, or an options hash" unless settings.is_a?(Hash)

      unknown = settings.keys - [:fields, :tag, :encoder, :fragment_size, :number_of_fragments]
      raise ArgumentError, "Unknown highlight options: #{unknown.join(', ')}" unless unknown.empty?

      selected = settings[:fields] || query.highlight_fields
      empty = {} #: highlight_settings
      @fields = if selected.is_a?(Hash)
        selected.to_h { |name, value| [name.to_s, value || empty] }
      else
        selected.to_h { |name| [name.to_s, empty] }
      end
      @settings = settings.except(:fields) #: highlight_settings
      @fields.each do |name, overrides|
        SearchField.new(query.model, name, match: :exact)
        invalid = overrides.keys - [:tag, :encoder, :fragment_size, :number_of_fragments]
        raise ArgumentError, "Unknown highlight field options: #{invalid.join(', ')}" unless invalid.empty?
      end
    end

    def columns
      @fields.keys.map { |name| name.split('.').first.to_s }.uniq
    end

    def call(rows)
      output = rows.map { {} } #: Array[Hash[String, Array[String]]]
      return output if rows.empty?

      @query.model.with_connection do |connection|
        highlighter = Highlighter.new(connection)
        @fields.each do |name, overrides|
          texts = rows.map { |row| field_value(row, name) }
          settings = @settings.merge(overrides) #: highlight_settings
          matching = @query.highlight_matches(name, texts: texts)
          whole_fields = highlighter.whole_fields(matching, **settings)
          spans = @query.highlight_spans(name, texts: texts)
          values = if spans
            highlighter.fragments_from_spans(texts, spans, **settings)
          else
            query = @query.highlight_query(name, texts: texts)
            highlighter.fragments_many(texts, query, **settings)
          end
          values.each_with_index do |fragments, index|
            complete = whole_fields.fetch(index)
            fragments = complete unless complete.empty?
            output.fetch(index)[name] = fragments unless fragments.empty?
          end
        end
      end
      output
    end

    private

    def field_value(row, name)
      value = row #: result_value
      name.split('.').each do |part|
        return unless value.is_a?(Hash)

        value = value[part]
      end
      value.to_s unless value.nil? || value.is_a?(Hash) || value.is_a?(Array)
    end
  end
end
