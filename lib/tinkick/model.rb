# frozen_string_literal: true

require_relative "relation"

module Tinkick
  module Model
    def tinkick(searchable: nil, default_fields: nil, match: :word)
      # @type self: singleton(ActiveRecord::Base)
      raise ArgumentError, "Only call tinkick once per model" if tinkick_options

      @tinkick_options = { searchable: searchable, default_fields: default_fields, match: match }
      singleton_class.alias_method(:search, :tinkick_search) unless respond_to?(:search, true)
    end

    def tinkick_options
      # @type self: singleton(ActiveRecord::Base)
      @tinkick_options || (superclass.respond_to?(:tinkick_options) ? superclass.public_send(:tinkick_options) : nil)
    end

    def tinkick_search(term = "*", fields: nil, misspellings: true, where: {}, order: nil, limit: nil, offset: nil, page: nil, per_page: nil, padding: nil, match: nil, operator: "and", load: true, total_entries: nil)
      # @type self: singleton(ActiveRecord::Base)
      options = tinkick_options
      raise Error, "Declare tinkick on #{name} before calling tinkick_search" unless options
      raise Error, "search must be called on model, not relation" if current_scope

      schema = tinkick_schema
      fields ||= options[:default_fields] || options[:searchable] || schema[:data_fields].select { |field| [:text, :citext].include?(schema[:columns].fetch(field).type) }
      tinkick_validate_fields(schema, (options[:searchable] || []) + fields)

      Relation.new(self, term, fields: fields, misspellings: misspellings,
        where: where, order: order, limit: limit, offset: offset, page: page,
        per_page: per_page, padding: padding, match: match || options[:match],
        operator: operator, load: load, total_entries: total_entries)
    end

    private

    def tinkick_schema
      # @type self: singleton(ActiveRecord::Base)
      with_connection do |connection|
        unless connection.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
          raise Error, "Tinkick requires PostgreSQL with the TIN extension"
        end

        columns = columns_hash
        pool = connection_pool
        cached = @tinkick_schema
        return cached if cached && cached[:columns].equal?(columns) && cached[:pool].equal?(pool)

        unless connection.extension_enabled?("tin")
          raise Error, "#{name} requires TIN; add a Rails migration with enable_extension :tin"
        end

        data_fields = tinkick_data_fields(columns)
        missing = data_fields - columns.keys
        unless missing.empty?
          raise MissingFieldError, "#{name} has no columns #{missing.join(", ")}; add persisted or generated columns with a Rails migration. Ruby search_data values are not persisted by Tinkick"
        end

        index_fields = connection.select_values(Arel.sql(<<~SQL, table_name))
          SELECT attribute.attname
          FROM pg_catalog.pg_index AS index
          JOIN pg_catalog.pg_class AS index_class ON index_class.oid = index.indexrelid
          JOIN pg_catalog.pg_am AS access_method ON access_method.oid = index_class.relam
          JOIN pg_catalog.pg_attribute AS attribute
            ON attribute.attrelid = index.indrelid AND attribute.attnum = index.indkey[0]
          WHERE index.indrelid = pg_catalog.to_regclass(?)
            AND access_method.amname = 'tin'
            AND index.indisvalid AND index.indisready
            AND index.indpred IS NULL AND index.indexprs IS NULL AND index.indnkeyatts = 1
        SQL

        @tinkick_schema = { columns: columns, pool: pool, data_fields: data_fields, index_fields: index_fields }
      end
    end

    def tinkick_data_fields(columns)
      # @type self: singleton(ActiveRecord::Base)
      return columns.keys unless method_defined?(:search_data)

      begin
        data = new.public_send(:search_data)
      rescue StandardError => error
        raise Error, "#{name}#search_data must run safely on a new instance (#{error.class}). Move derived data to persisted or generated columns with Rails migrations and return their keys without requiring saved records or associations"
      end
      raise Error, "#{name}#search_data must return a Hash of column names" unless data.is_a?(Hash)

      data.keys.map(&:to_s)
    end

    def tinkick_validate_fields(schema, fields)
      # @type self: singleton(ActiveRecord::Base)
      fields.each do |field|
        field = field.to_s
        column = schema[:columns][field]
        unless column
          raise MissingFieldError, "#{name} has no column #{field.inspect}; add a persisted or generated column with a Rails migration"
        end
        unless [:text, :citext].include?(column.type)
          raise InvalidQueryError, "#{name}.#{field} must be a text or citext column with a TIN index"
        end
        unless schema[:index_fields].include?(field)
          raise Error, "#{name}.#{field} requires a valid, nonpartial TIN index on the column; add a Rails migration with add_index #{table_name.inspect}, #{field.inspect}, using: :tin"
        end
      end
    end
  end
end
