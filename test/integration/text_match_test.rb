# frozen_string_literal: true

require_relative "../../lib/tinkick/text_match"
require_relative "../integration_helper"

class TextMatchTest < TinkickIntegrationTest
  def test_matches_whole_field_prefix_substring_and_suffix
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Ruby on Rails")

    assert_equal [product.id], ids("ruby on", :text_start)
    assert_empty ids("on", :text_start)
    assert_equal [product.id], ids("y on r", :text_middle)
    assert_equal [product.id], ids("on rails", :text_end)
    assert_empty ids("ruby", :text_end)
  end

  def test_normalizes_case_and_accents_without_tokenizing
    product = tinkick_test_products(:red_apple)
    product.update!(name: "JALAPEÑO Straße Æsir")

    assert_equal [product.id], ids("jalapeno strasse ae", :text_start)
    assert_equal [product.id], ids("PEÑO STRAßE", :text_middle)
    assert_equal [product.id], ids("STRASSE AESIR", :text_end)
    assert_empty ids("strasse jalapeno", :text_middle)
  end

  def test_preserves_whitespace_and_newlines
    product = tinkick_test_products(:red_apple)
    product.update!(name: "  Red  Apple\nPie  ")

    assert_equal [product.id], ids("  red ", :text_start)
    assert_empty ids("red", :text_start)
    assert_empty ids("red apple", :text_middle)
    assert_equal [product.id], ids("apple\npie", :text_middle)
    assert_equal [product.id], ids("pie  ", :text_end)
    assert_empty ids("pie", :text_end)
  end

  def test_wildcards_backslashes_and_query_syntax_remain_literal
    product = tinkick_test_products(:red_apple)
    product.update!(name: "10%_OFF\\deal (a|b).*")

    assert_equal [product.id], ids("10%_", :text_start)
    assert_equal [product.id], ids("%", :text_middle)
    assert_equal [product.id], ids("_", :text_middle)
    assert_equal [product.id], ids("\\", :text_middle)
    assert_equal [product.id], ids("(a|b).*", :text_end)
    assert_empty ids("' OR true --", :text_middle)
    assert_equal 2, SearchProduct.count
  end

  def test_empty_query_and_null_fields_do_not_match
    product = tinkick_test_products(:red_apple)
    product.update!(description: nil)
    tinkick_test_products(:green_pear).update!(description: "")

    [:text_start, :text_middle, :text_end].each do |mode|
      assert_empty ids("", mode, column: :description)
      assert_empty ids("a", mode, column: :description)
    end

    product.update!(description: " ")
    assert_equal [product.id], ids(" ", :text_middle, column: :description)
  end

  def test_uses_normalized_unicode_codepoints_for_the_fifty_character_limit
    product = tinkick_test_products(:red_apple)
    product.update!(name: "😀" * 60)

    [:text_start, :text_middle, :text_end].each do |mode|
      assert_equal [product.id], ids("😀" * 50, mode)
      assert_empty ids("😀" * 51, mode)
    end

    product.update!(name: "Æ" * 30)
    assert_equal [product.id], ids("Æ" * 25, :text_start)
    assert_empty ids("Æ" * 26, :text_start)
  end

  def test_zero_edit_distance_is_literal
    expected = [tinkick_test_products(:red_apple).id]

    assert_equal expected, ids("red app", :text_start, misspellings: { edit_distance: 0 })
    assert_equal expected, ids("red app", :text_start, misspellings: { distance: 0 })
    assert_empty ids("red apl", :text_start, misspellings: { edit_distance: 0 })
  end

  def test_rejects_invalid_match_modes_and_misspelling_settings
    assert_raises(ArgumentError) { ids("red", :word_start) }
    assert_raises(ArgumentError) { ids("red", :text_start, misspellings: { edit_distance: -1 }) }
    assert_raises(ArgumentError) { ids("red", :text_start, misspellings: { edit_distance: 0, unexpected: true }) }
    assert_raises(ArgumentError) { ids("red", :text_start, misspellings: { edit_distance: 0, prefix_length: -1 }) }
    assert_raises(ArgumentError) { ids("red", :text_start, misspellings: { edit_distance: 0, transpositions: nil }) }
  end

  def test_warns_about_the_sql_scan_path
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)

    ids("red", :text_start)

    assert_includes output.string, "whole-field SQL normalization"
    assert_includes output.string, "can scan rows outside TIN"
    assert_includes output.string, "word_start"
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def ids(term, match, column: :name, misspellings: false)
    column_sql = SearchProduct.connection.quote_column_name(column)
    sql, values = Tinkick::TextMatch.new(SearchProduct).predicate(column_sql, term, match: match, misspellings: misspellings)
    SearchProduct.where(Arel.sql(sql, *values)).order(:id).pluck(:id)
  end
end
