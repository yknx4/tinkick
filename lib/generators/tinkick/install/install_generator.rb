# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record/migration"

module Tinkick
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", File.dirname(__FILE__))
      desc "Creates a migration to enable TIN. Rollback preserves the shared extension."

      def create_migration_file
        migration_template "enable_tin.rb.tt", "db/migrate/enable_tin_for_tinkick.rb"
      end
    end
  end
end
