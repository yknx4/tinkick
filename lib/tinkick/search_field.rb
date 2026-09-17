# frozen_string_literal: true

require "active_record"
require_relative "errors"

module Tinkick
  class SearchField
    def initialize(model, name, match: :word)
      @model = model
      parts = name.split(".", -1)
      @root = parts.shift.to_s
      @path = parts
      column = model.columns_hash[@root]
      unless column
        raise MissingFieldError, "#{model.name} has no column #{@root.inspect}; add it with a Rails migration before searching"
      end
      array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
      if json?
        if @path.any? { |key| key.empty? || key.include?("\0") }
          raise ArgumentError, "JSON search paths require nonempty keys without null bytes"
        end
        unless column.type == :jsonb && !array
          raise InvalidQueryError, "#{model.name}.#{@root} must be a nonarray JSONB column for dotted search paths"
        end
      else
        types = [:exact, :text_start, :text_middle, :text_end].include?(match) ? [:text, :citext, :string] : [:text, :citext]
        unless !array && types.include?(column.type)
          raise InvalidQueryError, "#{model.name}.#{name} must be a text or citext column with a TIN index"
        end
      end
    end

    def json?
      !@path.empty?
    end

    def text_sql
      expression(text: true)
    end

    def scalar_predicate
      return unless json?

      "jsonb_typeof(#{expression(text: false)}) IN ('string', 'number', 'boolean')"
    end

    def canonical_expression
      @model.with_connection do |connection|
        result = connection.select_value(Arel.sql(<<~SQL, @root)).to_s
          SELECT pg_catalog.quote_ident(?::text) FROM pg_catalog.pg_extension WHERE extname = 'tin'
        SQL
        @path.each_with_index do |key, index|
          operator = index == @path.length - 1 ? "->>" : "->"
          result = "(#{result} #{operator} #{connection.quote(key)}::text)"
        end
        result
      end
    end

    private

    def expression(text:)
      @model.with_connection do |connection|
        result = "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(@root)}"
        @path.each_with_index do |key, index|
          operator = text && index == @path.length - 1 ? "->>" : "->"
          result = "(#{result} #{operator} #{connection.quote(key)})"
        end
        result
      end
    end
  end
end
