# frozen_string_literal: true

require "digest"
require "rails/generators"
require "rails/generators/active_record/migration"

module Tinkick
  module Generators
    class IndexGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", File.dirname(__FILE__))
      desc "Creates one TIN index per field on an existing table. Use plain table and text/citext column names."
      argument :table_name, type: :string, required: true
      argument :fields, type: :array, required: true

      def create_migration_file
        unless [table_name, *fields].all? { |identifier| /\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/.match?(identifier) }
          raise Thor::Error, "Table and fields must be plain PostgreSQL identifiers (up to 63 characters); schema-qualified names and expressions are not supported"
        end
        raise Thor::Error, "Field names must be unique" unless fields.uniq.length == fields.length

        migration_template "add_tin_indexes.rb.tt", "db/migrate/#{migration_name}.rb"
      end

      private

      def migration_name
        name = "add_tin_indexes_to_#{table_name}_on_#{fields.join("_and_")}"
        return name if name.length <= 200

        "add_tin_indexes_to_#{table_name}_#{Digest::SHA256.hexdigest(name)[0, 10]}"
      end

      def index_name(field)
        name = "#{table_name}_#{field}_tin"
        return name if name.bytesize <= 63

        suffix = "_#{Digest::SHA256.hexdigest(name)[0, 10]}_tin"
        "#{name.byteslice(0, 63 - suffix.bytesize)}#{suffix}"
      end
    end
  end
end
