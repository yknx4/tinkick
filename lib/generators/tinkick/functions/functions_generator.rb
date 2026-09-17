# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record/migration"

module Tinkick
  module Generators
    class FunctionsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", File.dirname(__FILE__))
      desc "Creates an optional migration for bounded Unicode edit-distance compatibility functions."
      class_option :upgrade, type: :boolean, default: false, desc: "Add four-argument edit distance without rewriting an existing installation"

      def create_migration_file
        name = options["upgrade"] ? "add_tinkick_edit_distance" : "install_tinkick_functions"
        migration_template "#{name}.rb.tt", "db/migrate/#{name}.rb"
      end

      private

      def edit_distance_sql
        File.read(File.expand_path("templates/edit_distance.sql.tt", File.dirname(__FILE__)))
      end
    end
  end
end
