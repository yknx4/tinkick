# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record/migration"

module Tinkick
  module Generators
    class FunctionsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", File.dirname(__FILE__))
      desc "Creates an optional migration for bounded Unicode edit-distance compatibility functions."

      def create_migration_file
        migration_template "install_tinkick_functions.rb.tt", "db/migrate/install_tinkick_functions.rb"
      end
    end
  end
end
