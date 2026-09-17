# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/functions"

class FunctionsTest < TinkickIntegrationTest
  def test_finds_the_optional_function_without_installing_it
    assert_equal "tinkick.osa_distance", Tinkick::Functions.require!(SearchProduct)
  end

  def test_missing_function_reports_the_optional_migration
    path = File.expand_path("../db/migrate/20260917000008_install_tinkick_functions.rb", __dir__)
    namespace = Module.new
    namespace.module_eval(File.read(path), path)
    migration = namespace.const_get(:InstallTinkickFunctions).new
    capture_io { migration.migrate(:down) }

    error = assert_raises(Tinkick::Error) { Tinkick::Functions.require!(SearchProduct) }

    assert_includes error.message, "bin/rails generate tinkick:functions"
    assert_includes error.message, "bin/rails db:migrate"
    assert_includes error.message, "optional"
  end

  def test_exact_insert_delete_and_substitute_distances
    assert_equal 0, distance("apple", "apple", 0)
    assert_equal 1, distance("apple", "appl", 1)
    assert_equal 1, distance("appl", "apple", 1)
    assert_equal 1, distance("apple", "apxle", 1)
    assert_equal 2, distance("apple", "axxle", 2)
  end

  def test_adjacent_transpositions_follow_optimal_string_alignment
    assert_equal 1, distance("apple", "aplpe", 1)
    assert_equal 2, distance("abcd", "badc", 2)
    assert_equal 3, distance("ca", "abc", 2)
    assert_equal 3, distance("abc", "ca", 2)
    assert_equal 2, distance("abc", "bca", 2)
  end

  def test_caps_return_a_value_above_the_requested_distance
    assert_equal 1, distance("apple", "pear", 0)
    assert_equal 2, distance("apple", "pear", 1)
    assert_equal 3, distance("apple", "pear", 2)
    assert_equal 2, distance("", "abc", 1)
    assert_equal 2, distance("abc", "", 1)
    assert_equal 0, distance("", "", 0)
    assert_equal 2, distance("", "ab", 2)
  end

  def test_unicode_uses_codepoints_without_implicit_normalization
    assert_equal 1, distance("a𐐨b", "ab𐐨", 1)
    assert_equal 1, distance("😀🌍", "🌍😀", 1)
    assert_equal 1, distance("Jalapeño", "jalapeño", 1)
    assert_equal 1, distance("ñ", "n", 1)
    assert_equal 2, distance("ñ", "n\u0303", 2)
  end

  def test_long_tokens_use_bounded_rows
    prefix = "𐐨" * 2_000
    assert_equal 1, distance("#{prefix}ab", "#{prefix}ba", 1)
    assert_equal 3, distance("#{prefix}abc", "#{prefix}xyz", 2)
    assert_equal 1, distance(prefix, "#{prefix}a", 1)
  end

  def test_null_inputs_remain_null_and_negative_caps_fail
    assert_nil distance(nil, "apple", 1)
    assert_nil distance("apple", nil, 1)
    assert_nil distance("apple", "apple", nil)
    error = assert_raises(ActiveRecord::StatementInvalid) { distance("apple", "apple", -1) }
    assert_includes error.message, "max_distance must be nonnegative"
  end

  def test_function_is_safe_for_sql_query_composition
    row = SearchProduct.connection.select_one(<<~SQL)
      SELECT proc.provolatile, proc.proparallel, proc.proisstrict, proc.prosecdef
      FROM pg_catalog.pg_proc AS proc
      WHERE proc.oid = 'tinkick.osa_distance(text,text,integer)'::regprocedure
    SQL

    assert_equal({ "provolatile" => "i", "proparallel" => "s", "proisstrict" => true, "prosecdef" => false }, row)
    assert_equal ["Red Apple"], SearchProduct.where("tinkick.osa_distance(name, ?, 1) <= 1", "Red Aplpe").pluck(:name)
  end

  def test_loading_optional_function_support_does_not_connect
    output, status = Open3.capture2e(
      RbConfig.ruby, "-Ilib", "-e",
      'require "tinkick/functions"; abort "Unexpected connection" if ActiveRecord::Base.connected?',
    )

    assert_predicate status, :success?, output
  end

  private

  def distance(source, target, maximum)
    SearchProduct.connection.select_value(Arel.sql("SELECT tinkick.osa_distance(?, ?, ?)", source, target, maximum))
  end
end
