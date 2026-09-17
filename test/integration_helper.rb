# frozen_string_literal: true

require_relative "test_helper"
require "active_record"
require "active_support/test_case"

# Rails' test helper includes these callbacks on this same class. Including them
# on a subclass first would run fixture setup and teardown twice after app boot.
ActiveSupport::TestCase.include(ActiveRecord::TestFixtures)

ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

ActiveRecord::Base.with_connection do |connection|
  database = connection.select_value("SELECT current_database()")
  raise "Refusing to run tests against #{database.inspect}; expected tinkick_test" unless database == "tinkick_test"

  raise "tinkick_test requires the TIN extension" unless connection.extension_enabled?("tin")

  ActiveRecord::MigrationContext.new(File.expand_path("db/migrate", __dir__)).migrate
end

class SearchProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
end

class TinkickIntegrationTest < ActiveSupport::TestCase
  self.fixture_paths = [File.expand_path("fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_products: SearchProduct)
  fixtures :tinkick_test_products
end
