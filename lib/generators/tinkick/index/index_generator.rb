# frozen_string_literal: true

require "digest"
require "rails/generators"
require "rails/generators/active_record/migration"

module Tinkick
  module Generators
    class IndexGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", File.dirname(__FILE__))
      desc "Creates one TIN index per text/citext column or dotted JSONB text path on an existing table."
      argument :table_name, type: :string, required: true
      argument :fields, type: :array, required: true

      def create_migration_file
        unless plain_identifier?(table_name) && fields.all? { |field| valid_field?(field) }
          raise Thor::Error, "Table and root columns must be plain PostgreSQL identifiers (up to 63 characters); dotted JSONB paths must have non-empty keys without null bytes; raw SQL expressions are not supported"
        end
        raise Thor::Error, "Field names must be unique" unless fields.uniq.length == fields.length

        migration_template "add_tin_indexes.rb.tt", "db/migrate/#{migration_name}.rb"
      end

      private

      def plain_identifier?(identifier)
        /\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/.match?(identifier)
      end

      def valid_field?(field)
        parts = field.split(".", -1)
        plain_identifier?(parts.shift.to_s) && parts.all? { |part| !part.empty? && !part.include?("\0") }
      end

      def migration_name
        original = "add_tin_indexes_to_#{table_name}_on_#{fields.join("_and_")}"
        name = original.gsub(/[^a-zA-Z0-9_]/, "_")
        name += "_#{Digest::SHA256.hexdigest(original)[0, 10]}" if fields.any? { |field| field.include?(".") }
        return name if name.length <= 200

        "add_tin_indexes_to_#{table_name}_#{Digest::SHA256.hexdigest(original)[0, 10]}"
      end

      def index_name(field)
        name = "#{table_name}_#{field}_tin"
        return name if !field.include?(".") && name.bytesize <= 63

        suffix = "_#{Digest::SHA256.hexdigest(name)[0, 10]}_tin"
        prefix = "#{table_name}_#{field}".gsub(/[^a-zA-Z0-9_]/, "_")
        "#{prefix.byteslice(0, 63 - suffix.bytesize)}#{suffix}"
      end

      def index_expression(field)
        return field.inspect unless field.include?(".")

        "jsonb_expression(#{field.split(".").map(&:inspect).join(", ")})"
      end
    end
  end
end
