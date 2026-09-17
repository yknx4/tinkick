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
    assert_raises(ArgumentError) { ids("red", :text_start, misspellings: { edit_distance: 0.0 }) }
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

  def test_fuzzy_text_matches_substitution_insertion_deletion_and_swaps
    expected = [tinkick_test_products(:red_apple).id]

    assert_equal expected, ids("rex app", :text_start, misspellings: true)
    assert_equal expected, ids("re app", :text_start, misspellings: true)
    assert_equal expected, ids("redd app", :text_start, misspellings: true)
    assert_equal expected, ids("rde app", :text_start, misspellings: true)
    assert_equal expected, ids("d xp", :text_middle, misspellings: true)
    assert_equal expected, ids("aplpe", :text_end, misspellings: true)
    assert_empty ids("rxx app", :text_start, misspellings: true)
  end

  def test_fuzzy_text_honors_fixed_prefix_and_transposition_settings
    expected = [tinkick_test_products(:red_apple).id]

    assert_empty ids("xed ap", :text_start, misspellings: { prefix_length: 1 })
    assert_equal expected, ids("rex ap", :text_start, misspellings: { prefix_length: 2 })
    assert_empty ids("rde app", :text_start, misspellings: { transpositions: false })
    assert_empty ids("rde app", :text_start, misspellings: { prefix_length: 2 })
    assert_equal expected, ids("red applx", :text_start, misspellings: { distance: 1 })
    assert_raises(ArgumentError) { ids("red", :text_start, misspellings: { edit_distance: 3 }) }
  end

  def test_fuzzy_text_normalizes_accents_and_preserves_literal_regex_characters
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Jalapeño (a|b).* 😀x😀")

    assert_equal [product.id], ids("JALAPENA", :text_start, misspellings: true)
    assert_equal [product.id], ids("(a|b).x", :text_middle, misspellings: true)
    assert_equal [product.id], ids("😀y😀", :text_end, misspellings: true)
    assert_empty ids("(?s).*", :text_middle, misspellings: true)
    assert_empty ids("' OR true --", :text_middle, misspellings: true)
  end

  def test_fuzzy_text_uses_absolute_field_anchors_and_can_edit_newlines
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Header\nRed Apple\nFooter")

    assert_empty ids("rex app", :text_start, misspellings: true)
    assert_empty ids("red applx", :text_end, misspellings: true)
    assert_equal [product.id], ids("headerxred", :text_start, misspellings: true)
    assert_equal [product.id], ids("applexfooter", :text_end, misspellings: true)
    assert_equal [product.id], ids("red applx", :text_middle, misspellings: true)
  end

  def test_fuzzy_text_limits_candidate_grams_to_fifty_codepoints
    product = tinkick_test_products(:red_apple)
    product.update!(name: "😀" * 60)

    [:text_start, :text_middle, :text_end].each do |mode|
      assert_equal [product.id], ids("😀" * 51, mode, misspellings: true)
      assert_empty ids("😀" * 52, mode, misspellings: true)
      assert_empty ids("", mode, misspellings: true)
    end
  end

  def test_two_edit_text_matches_candidate_grams_in_all_positions
    expected = [tinkick_test_products(:red_apple).id]

    [:text_start, :text_middle, :text_end].each do |mode|
      assert_equal expected, ids("rxx apple", mode, misspellings: { edit_distance: 2 })
      assert_empty ids("rxx apple", mode, misspellings: true)
      assert_empty ids("rxx apxle", mode, misspellings: { edit_distance: 2 })
    end
  end

  def test_two_edit_text_honors_transpositions_and_fixed_prefix
    product = tinkick_test_products(:red_apple)
    product.update!(name: "abcdef")

    assert_equal [product.id], ids("badcef", :text_start, misspellings: { edit_distance: 2 })
    assert_empty ids("badcef", :text_start, misspellings: { edit_distance: 2, transpositions: false })
    assert_empty ids("badcef", :text_start, misspellings: { edit_distance: 2, prefix_length: 1 })
    assert_equal [product.id], ids("abcdfe", :text_start, misspellings: { edit_distance: 2, prefix_length: 4 })
    assert_equal [product.id], ids("abcdef", :text_start, misspellings: { edit_distance: 2, prefix_length: 20 })
  end

  def test_two_edit_text_enumerates_infix_positions_and_normalizes_unicode
    product = tinkick_test_products(:red_apple)
    product.update!(name: "first\nJalapeño\nlast")

    assert_equal [product.id], ids("XALAPENA", :text_middle, misspellings: { edit_distance: 2 })
    assert_empty ids("XALAPENA", :text_start, misspellings: { edit_distance: 2 })
    assert_empty ids("XALAPENA", :text_end, misspellings: { edit_distance: 2 })
    assert_empty ids("' OR true --", :text_middle, misspellings: { edit_distance: 2 })
    product.update!(description: nil)
    assert_empty ids("apple", :text_middle, column: :description, misspellings: { edit_distance: 2 })
  end

  def test_two_edit_text_preserves_the_fifty_codepoint_gram_limit
    product = tinkick_test_products(:red_apple)
    product.update!(name: "😀" * 60)

    [:text_start, :text_middle, :text_end].each do |mode|
      assert_equal [product.id], ids("😀" * 52, mode, misspellings: { edit_distance: 2 })
      assert_empty ids("😀" * 53, mode, misspellings: { edit_distance: 2 })
    end
    assert_equal [product.id], ids("😀" * 52, :text_start, misspellings: { edit_distance: 2, transpositions: false })
  end

  def test_fuzzy_text_requires_positive_scaled_similarity_for_short_grams
    product = tinkick_test_products(:red_apple)
    product.update!(name: "ab")
    tinkick_test_products(:green_pear).update!(name: "zz")

    [1, 2].each do |distance|
      assert_equal [product.id], ids("a", :text_start, misspellings: { edit_distance: distance })
      assert_empty ids("b", :text_start, misspellings: { edit_distance: distance })
      assert_equal [product.id], ids("b", :text_end, misspellings: { edit_distance: distance })
    end
    assert_empty ids("abcd", :text_start, misspellings: { edit_distance: 2 })

    product.update!(name: "a")
    [1, 2].each { |distance| assert_empty ids("ab", :text_start, misspellings: { edit_distance: distance }) }
  end

  def test_two_edit_text_warns_about_gram_enumeration_and_distance_cost
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)

    ids("rxx apple", :text_middle, misspellings: { edit_distance: 2 })

    assert_includes output.string, "enumerates candidate grams"
    assert_includes output.string, "edit-distance comparisons"
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
