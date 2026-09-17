# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "tinkick"

module TinkickTestApplication
  class Application < Rails::Application
    config.load_defaults(8.0)
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "tinkick-local-test-application-only"
    config.hosts = ["www.example.com", "localhost", "127.0.0.1"]
    config.logger = Logger.new($stdout)
    config.log_level = :warn
    config.active_record.schema_format = :sql
    config.paths["db/migrate"] = [File.expand_path("../../db/migrate", __dir__)]
    config.active_record.dump_schema_after_migration = false
    # The router rejects the dynamic PL/pgSQL used by this optional fixture
    # audit. This app has no foreign keys; PostgreSQL constraints stay enabled.
    config.active_record.verify_foreign_keys_for_fixtures = false
  end
end
