# frozen_string_literal: true

require_relative "../../lib/tinkick/extensions"
require_relative "../integration_helper"

class ExtensionsTest < TinkickIntegrationTest
  class RemoveOptionalExtensions < ActiveRecord::Migration[8.0]
    def up
      raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"

      %w[unaccent fuzzystrmatch pg_trgm].each do |name|
        execute "DROP EXTENSION #{connection.quote_column_name(name)} RESTRICT"
      end
    end
  end

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

  def test_native_search_and_filters_work_without_optional_extensions
    # The fixture transaction restores extensions after this test. RESTRICT
    # refuses to remove anything with an unexpected dependent application object.
    capture_io { RemoveOptionalExtensions.new.migrate(:up) }
    model = Class.new(SearchProduct) { tinkick searchable: [:name] }

    %w[unaccent fuzzystrmatch pg_trgm].each do |name|
      refute SearchProduct.connection.extension_enabled?(name)
    end
    assert_equal ["Red Apple"], model.search("apple", misspellings: false).map(&:name)
    assert_equal ["Red Apple"], model.search("aplpe").map(&:name)
    assert_equal ["Red Apple"], model.search("*", where: { name: /Apple\z/ }).map(&:name)
    assert_equal ["Red Apple"], model.search("Red Apple", match: :exact).map(&:name)

    error = assert_raises(Tinkick::Error) { model.search("red", match: :text_start).to_a }
    assert_includes error.message, 'enable_extension "unaccent"'
    error = assert_raises(Tinkick::Error) do
      model.search("apple", match: :word_middle, misspellings: { edit_distance: 2, transpositions: false }).to_a
    end
    assert_includes error.message, 'enable_extension "fuzzystrmatch"'
  end
end
