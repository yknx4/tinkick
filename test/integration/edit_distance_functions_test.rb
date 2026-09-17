# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/functions"

class EditDistanceFunctionsTest < TinkickIntegrationTest
  def test_finds_the_optional_four_argument_function
    assert_equal "tinkick.edit_distance", Tinkick::Functions.require_edit_distance!(SearchProduct)
    assert_equal "tinkick.osa_distance", Tinkick::Functions.require!(SearchProduct)
  end

  def test_transpositions_can_be_enabled_or_disabled
    assert_equal 1, distance("apple", "aplpe", 2, true)
    assert_equal 2, distance("apple", "aplpe", 2, false)
    assert_equal 2, distance("abcd", "badc", 2, true)
    assert_equal 3, distance("abcd", "badc", 2, false)
    assert_equal 3, distance("ca", "abc", 2, true)
    assert_equal 3, distance("ca", "abc", 2, false)
  end

  def test_long_tokens_work_without_the_fuzzystrmatch_character_limit
    prefix = "𐐨" * 1_000
    assert_equal 1, distance("#{prefix}ab", "#{prefix}ba", 1, true)
    assert_equal 2, distance("#{prefix}ab", "#{prefix}ba", 2, false)
    assert_equal 3, distance("#{prefix}abcd", "#{prefix}badc", 2, false)
    assert_equal 1, distance(prefix, "#{prefix}a", 1, false)
    assert_equal 1, distance("#{prefix}a", prefix, 1, false)
    assert_equal 2, distance("#{prefix}abc", "#{prefix}axz", 2, false)
  end

  def test_caps_empty_strings_and_unicode_remain_explicit
    [true, false].each do |transpositions|
      assert_equal 0, distance("apple", "apple", 0, transpositions)
      assert_equal 1, distance("apple", "pear", 0, transpositions)
      assert_equal 2, distance("apple", "pear", 1, transpositions)
      assert_equal 3, distance("apple", "pear", 2, transpositions)
      assert_equal 0, distance("", "", 0, transpositions)
      assert_equal 2, distance("", "ab", 2, transpositions)
      assert_equal 2, distance("abc", "", 1, transpositions)
      assert_equal 1, distance("Jalapeño", "jalapeño", 1, transpositions)
      assert_equal 2, distance("ñ", "n\u0303", 2, transpositions)
    end
    assert_equal 1, distance("😀🌍", "🌍😀", 1, true)
    assert_equal 2, distance("😀🌍", "🌍😀", 2, false)
  end

  def test_null_arguments_and_negative_caps_follow_the_existing_contract
    assert_nil distance(nil, "apple", 1, false)
    assert_nil distance("apple", nil, 1, false)
    assert_nil distance("apple", "apple", nil, false)
    assert_nil distance("apple", "apple", 1, nil)
    error = assert_raises(ActiveRecord::StatementInvalid) { distance("apple", "apple", -1, false) }
    assert_includes error.message, "max_distance must be nonnegative"
  end

  def test_missing_function_has_an_upgrade_migration_error_without_blocking_native_search
    path = File.expand_path("../db/migrate/20260917000012_add_tinkick_edit_distance.rb", __dir__)
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    migration = namespace.const_get(:AddTinkickEditDistance).new
    capture_io { migration.migrate(:down) }

    error = assert_raises(Tinkick::Error) { Tinkick::Functions.require_edit_distance!(SearchProduct) }
    assert_includes error.message, "bin/rails generate tinkick:functions --upgrade"
    assert_includes error.message, "bin/rails db:migrate"
    assert_equal "tinkick.osa_distance", Tinkick::Functions.require!(SearchProduct)
    assert_equal 1, SearchProduct.connection.select_value("SELECT tinkick.osa_distance('apple', 'aplpe', 1)")
    assert_equal ["Red Apple"], Tinkick::Query.new(SearchProduct, "apple", fields: [:name], misspellings: false).records.map(&:name)
  end

  def test_function_retains_safe_query_composition_attributes
    row = SearchProduct.connection.select_one(<<~SQL)
      SELECT proc.provolatile, proc.proparallel, proc.proisstrict, proc.prosecdef
      FROM pg_catalog.pg_proc AS proc
      WHERE proc.oid = 'tinkick.edit_distance(text,text,integer,boolean)'::regprocedure
    SQL

    assert_equal({ "provolatile" => "i", "proparallel" => "s", "proisstrict" => true, "prosecdef" => false }, row)
    assert_equal ["Red Apple"], SearchProduct.where("tinkick.edit_distance(name, ?, 2, false) <= 2", "Red Aplpe").pluck(:name)
  end

  private

  def distance(source, target, maximum, transpositions)
    SearchProduct.connection.select_value(Arel.sql("SELECT tinkick.edit_distance(?, ?, ?, ?)", source, target, maximum, transpositions))
  end
end
