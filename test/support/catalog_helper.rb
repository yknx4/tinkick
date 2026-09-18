# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test_helper"
require_relative "../dummy/config/environment"
require_relative "../integration_helper"
require "rails/test_help"

class CatalogIntegrationTest < ActionDispatch::IntegrationTest
  self.fixture_paths = [File.expand_path("../dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_catalog_entries: CatalogEntry)
  fixtures :tinkick_test_catalog_entries

  private

  def entry(key)
    tinkick_test_catalog_entries(key)
  end

  def search(term, **options)
    CatalogEntry.tinkick_search(term, misspellings: false, **options)
  end
end
