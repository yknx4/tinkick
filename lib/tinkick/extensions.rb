# frozen_string_literal: true

require "active_record"
require_relative "errors"

module Tinkick
  module Extensions
    class << self
      def require!(model, name)
        schema = model.with_connection do |connection|
          connection.select_value(Arel.sql(<<~SQL, name))
            SELECT namespace.nspname
            FROM pg_catalog.pg_extension AS extension
            JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = extension.extnamespace
            WHERE extension.extname = ?
          SQL
        end
        unless schema.is_a?(String)
          raise Error, "The #{name} extension is required for this search feature. Add enable_extension #{name.inspect} to a Rails migration and run bin/rails db:migrate."
        end

        schema
      end
    end
  end
end
