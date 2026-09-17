# frozen_string_literal: true

require "base64"
require "json"
require "date"
require "time"

module Tinkick
  # Column cursors describe a position, not authorization or a database snapshot.
  class Keyset
    def initialize(model, order)
      @model = model
      primary_key = model.primary_key
      unless primary_key.is_a?(String)
        raise InvalidQueryError, "#{model.name} requires a single primary key for keyset pagination"
      end

      @order = order.nil? ? [] : normalize_order(order)
      if @order.map(&:first).uniq.length != @order.length
        raise InvalidQueryError, "keyset order must not repeat columns"
      end
      @order << [primary_key, "asc"] unless @order.any? { |field, _direction| field == primary_key }
      @order.each { |field, _direction| validate_column(field) }
    end

    def order_sql
      @order.map { |field, direction| "#{quoted_column(field)} #{direction.upcase}" }.join(", ")
    end

    def apply(relation, cursor)
      values = decode(cursor)
      binds = [] #: Array[keyset_value]
      alternatives = @order.each_with_index.map do |(field, direction), index|
        equalities = @order.first(index).each_with_index.map do |(previous, _), previous_index|
          binds << values.fetch(previous_index)
          "#{quoted_column(previous)} = ?"
        end
        binds << values.fetch(index)
        comparison = direction == "asc" ? ">" : "<"
        "(#{(equalities + ["#{quoted_column(field)} #{comparison} ?"]).join(" AND ")})"
      end
      relation.where(Arel.sql("(#{alternatives.join(" OR ")})", *binds))
    end

    def encode(attributes)
      values = @order.map { |field, _| serialize_value(attributes.fetch(field)) }
      Base64.urlsafe_encode64(JSON.generate(version: 1, table: @model.table_name, order: @order, values: values), padding: false)
    end

    private

    def decode(cursor)
      raise InvalidQueryError, "invalid keyset cursor" unless cursor.match?(/\A[A-Za-z0-9_-]+\z/)

      # JSON is an external input boundary; each shape and scalar is checked below.
      payload = JSON.parse(Base64.urlsafe_decode64(cursor)) #: result_value
      unless payload.is_a?(Hash) && payload["version"] == 1 && payload["table"] == @model.table_name && payload["order"] == @order
        raise InvalidQueryError, "keyset cursor does not match this table, order, or cursor version"
      end
      values = payload["values"]
      unless values.is_a?(Array) && values.length == @order.length
        raise InvalidQueryError, "invalid keyset cursor values"
      end

      @order.each_with_index.map { |(field, _), index| cast_value(field, values.fetch(index)) }
    rescue JSON::ParserError, ArgumentError, RangeError
      raise InvalidQueryError, "invalid keyset cursor values"
    end

    def cast_value(field, value)
      column = @model.columns_hash.fetch(field)
      valid = case column.type
      when :integer
        value.is_a?(Integer)
      when :text, :string, :citext
        value.is_a?(String)
      when :uuid
        value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
      when :date
        value.is_a?(String) && Date.iso8601(value)
      when :datetime, :timestamp, :timestamptz
        value.is_a?(String) && Time.iso8601(value)
      when :decimal
        value.is_a?(String) && BigDecimal(value).finite?
      end
      raise InvalidQueryError, "invalid keyset cursor value for #{field}" unless valid

      type = @model.type_for_attribute(field)
      # The column types above limit Active Record's cast result to these scalars.
      cast = type.cast(value) #: keyset_value?
      raise InvalidQueryError, "invalid keyset cursor value for #{field}" if cast.nil?

      type.serialize(cast)
      cast
    end

    def serialize_value(value)
      case value
      when Integer, String
        value
      when Time
        value.iso8601(6)
      when Date
        value.iso8601
      when BigDecimal
        value.to_s("F")
      else
        raise InvalidQueryError, "keyset cursor requires nonnullable scalar column values"
      end
    end

    def normalize_order(value)
      case value
      when Array
        value.flat_map { |entry| normalize_order(entry) }
      when Hash
        value.map do |field, direction|
          normalized = direction.to_s.downcase
          raise InvalidQueryError, "keyset order direction must be asc or desc" unless ["asc", "desc"].include?(normalized)

          [field.to_s, normalized]
        end
      else
        [[value.to_s, "asc"]]
      end
    end

    def validate_column(field)
      if ["_score", "_tinkick_score"].include?(field)
        raise InvalidQueryError, "keyset pagination requires column order; use countless: true for relevance ranking"
      end
      column = @model.columns_hash[field]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{field.inspect}; add it with a Rails migration before searching"
      end
      if column.null
        raise InvalidQueryError, "keyset order column #{field} must be NOT NULL; add a Rails migration or choose another order"
      end
      array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
      unless [:integer, :text, :string, :citext, :uuid, :date, :datetime, :timestamp, :timestamptz, :decimal].include?(column.type) && !array
        raise InvalidQueryError, "keyset order column #{field} must be an integer, text, UUID, date, timestamp, or decimal scalar"
      end
    end

    def quoted_column(field)
      @model.with_connection do |connection|
        "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(field)}"
      end
    end
  end
end
