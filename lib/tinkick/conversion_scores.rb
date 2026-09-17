# frozen_string_literal: true

require "active_record"
require_relative "errors"

module Tinkick
  class ConversionScores
    def initialize(model, fields:, term:, factor: 1, case_sensitive: false)
      @model = model
      @fields = fields
      @term = term
      @factor = factor_number(factor)
      @case_sensitive = case_sensitive
      @warned = false
    end

    def empty?
      @fields.empty?
    end

    def score_sql(base_score)
      return base_score if empty?

      counts = @fields.map { |field| column_score(field) }.join(" + ")
      unless @warned
        message = "Tinkick: conversion scoring can sort matching rows instead of using native TIN top-k."
        message += " Case-insensitive matching iterates JSONB entries per row." unless @case_sensitive
        @model.logger&.warn(message)
        @warned = true
      end
      "((#{base_score})::double precision + ((#{counts}) * #{@factor})::double precision)"
    end

    private

    def factor_number(value)
      number = Float(value)
      unless number.is_a?(Float) && number.finite? && !number.negative?
        raise ArgumentError, "Conversion factor must be finite and nonnegative"
      end

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "Conversion factor must be a finite nonnegative number or numeric string"
    end

    def column_score(name)
      column = @model.columns_hash[name]
      unless column
        raise MissingFieldError, "#{@model.name} has no column #{name.inspect}; add a JSONB conversion column with a Rails migration"
      end
      array = column.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::Column) && column.array?
      unless column.type == :jsonb && !array
        raise InvalidQueryError, "#{@model.name}.#{name} must be a nonarray JSONB column for conversion scoring"
      end

      @model.with_connection do |connection|
        field = "#{connection.quote_table_name(@model.table_name)}.#{connection.quote_column_name(name)}"
        term = connection.quote(@term)
        if @case_sensitive
          checked_count("(#{field} ->> #{term})::numeric")
        else
          <<~SQL.squish
            (SELECT COALESCE(SUM(CASE WHEN lower(key) = lower(#{term})
              THEN #{checked_count("(value #>> '{}')::numeric")} ELSE 0 END), 0)
            FROM jsonb_each(NULLIF(#{field}, 'null'::jsonb)) AS tinkick_conversions(key, value))
          SQL
        end
      end
    end

    def checked_count(value)
      <<~SQL.squish
        CASE WHEN (#{value}) IS NULL THEN 0
          WHEN (#{value}) >= 0 AND (#{value}) < 'Infinity'::numeric THEN (#{value})
          ELSE ('conversion count must be finite and nonnegative: ' || (#{value})::text)::numeric
        END
      SQL
    end
  end
end
