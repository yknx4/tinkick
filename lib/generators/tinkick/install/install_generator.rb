# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record/migration"

module Tinkick
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", File.dirname(__FILE__))
      desc "Creates a migration to enable TIN. Rollback preserves the shared extension."
      class_option :unaccent, type: :boolean, default: false, desc: "Enable unaccent for accent-insensitive matching"
      class_option :fuzzystrmatch, type: :boolean, default: false, desc: "Enable fuzzystrmatch for application SQL"
      class_option :pg_trgm, type: :boolean, default: false, desc: "Enable pg_trgm for optional trigram indexes"

      def create_migration_file
        migration_template "enable_tin.rb.tt", "db/migrate/enable_tin_for_tinkick.rb"
      end

      private

      def extensions
        ["tin"] + %w[unaccent fuzzystrmatch pg_trgm].select { |name| options[name] }
      end
    end
  end
end
