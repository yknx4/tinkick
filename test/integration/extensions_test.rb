# frozen_string_literal: true

require_relative "../../lib/tinkick/extensions"
require_relative "../integration_helper"

class ExtensionsTest < TinkickIntegrationTest
  def test_returns_the_installed_extension_schema
    schema = Tinkick::Extensions.require!(SearchProduct, "tin")

    expected = SearchProduct.connection.select_value("SELECT extnamespace::regnamespace::text FROM pg_catalog.pg_extension WHERE extname = 'tin'")
    assert_equal expected, schema
  end

  def test_missing_extension_reports_an_actionable_migration
    error = assert_raises(Tinkick::Error) do
      Tinkick::Extensions.require!(SearchProduct, "tinkick_absent_test_extension")
    end

    assert_includes error.message, 'enable_extension "tinkick_absent_test_extension"'
    assert_includes error.message, "Rails migration"
    assert_includes error.message, "bin/rails db:migrate"
  end

  def test_extension_names_are_bound_values
    assert_raises(Tinkick::Error) { Tinkick::Extensions.require!(SearchProduct, "tin' OR true --") }
    assert SearchProduct.connection.extension_enabled?("tin")
  end

  def test_optional_extensions_can_be_called_through_their_actual_schema
    SearchProduct.with_connection do |connection|
      unaccent = connection.quote_column_name(Tinkick::Extensions.require!(SearchProduct, "unaccent"))
      fuzzystrmatch = connection.quote_column_name(Tinkick::Extensions.require!(SearchProduct, "fuzzystrmatch"))
      pg_trgm = connection.quote_column_name(Tinkick::Extensions.require!(SearchProduct, "pg_trgm"))

      assert_equal "Hotel", connection.select_value("SELECT #{unaccent}.unaccent('Hôtel')")
      assert_equal 1, connection.select_value("SELECT #{fuzzystrmatch}.levenshtein('ruby', 'rby')")
      assert_equal 1.0, connection.select_value("SELECT #{pg_trgm}.similarity('ruby', 'ruby')")
    end
  end

  def test_loading_extension_support_does_not_connect
    output, status = Open3.capture2e(
      RbConfig.ruby, "-Ilib", "-e",
      'require "tinkick/extensions"; abort "Unexpected connection" if ActiveRecord::Base.connected?',
    )

    assert_predicate status, :success?, output
  end
end
