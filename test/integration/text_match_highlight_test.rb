# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/text_match"

class TextMatchHighlightTest < Minitest::Test
  def test_exact_matching_preserves_case_accents_whitespace_and_empty_values
    texts = ["Jalapeño", "jalapeño", "Jalapeno", " Jalapeño", "Jalapeño", nil, ""]
    assert_equal ["Jalapeño", nil, nil, nil, "Jalapeño", nil, nil], matches(texts, "Jalapeño", :exact, misspellings: true)
    assert_equal [nil, "", nil], matches([nil, "", " "], "", :exact)
    assert_equal [nil, nil], matches(["Apple", "Applf"], "Applx", :exact, misspellings: { edit_distance: 2 })
  end

  def test_each_sql_mode_checks_whole_field_eligibility_and_returns_original_text
    texts = ["JALAPEÑO Street", "North Jalapeño Street", "North Jalapeño", "Other town", nil]
    assert_equal [texts[0], nil, nil, nil, nil], matches(texts, "jalapeno", :text_start)
    assert_equal [texts[0], texts[1], texts[2], nil, nil], matches(texts, "jalapeno", :text_middle)
    assert_equal [nil, nil, texts[2], nil, nil], matches(texts, "jalapeno", :text_end)

    text = "  Red  Apple\nPie  "
    assert_equal [text], matches([text], "apple\npie", :text_middle)
    assert_equal [nil], matches([text], "red apple", :text_middle)
    assert_equal [text], matches([text], "  red ", :text_start)
    assert_equal [text], matches([text], "pie  ", :text_end)
  end

  def test_user_values_remain_literal_and_return_unencoded_source
    text = "<b>10%_OFF\\deal</b> ' OR true --"
    assert_equal [text, nil], matches([text, "<b>10ABCoff deal</b>"], "10%_OFF\\", :text_middle)
    assert_equal [text, nil], matches([text, "Unrelated town"], "' OR true --", :text_end)
    assert_equal [text, nil], matches([text, "Unrelated town"], text, :exact)
    assert_equal [nil, nil], matches([text, "Unrelated town"], "' OR true --", :exact)
  end

  def test_fuzzy_modes_reuse_the_same_edit_distance_prefix_and_transposition_rules
    [:text_start, :text_middle, :text_end].each do |mode|
      texts = ["Red Apple", "Distant village", nil]
      assert_equal [nil, nil, nil], matches(texts, "rxx apple", mode, misspellings: true)
      assert_equal ["Red Apple", nil, nil], matches(texts, "rxx apple", mode, misspellings: { edit_distance: 2 })
    end

    texts = ["abcdef", "badcef"]
    assert_equal texts, matches(texts, "badcef", :text_start, misspellings: { edit_distance: 2 })
    assert_equal [nil, "badcef"], matches(texts, "badcef", :text_start, misspellings: { edit_distance: 2, transpositions: false })
    assert_equal [nil, "badcef"], matches(texts, "badcef", :text_start, misspellings: { edit_distance: 2, prefix_length: 1 })
  end

  def test_candidate_grams_retain_the_fifty_codepoint_boundary
    text = "😀" * 60
    [:text_start, :text_middle, :text_end].each do |mode|
      assert_equal [text], matches([text], "😀" * 50, mode)
      assert_equal [nil], matches([text], "😀" * 51, mode)
      assert_equal [text], matches([text], "😀" * 52, mode, misspellings: { edit_distance: 2 })
      assert_equal [nil], matches([text], "😀" * 53, mode, misspellings: { edit_distance: 2 })
      assert_equal [nil, nil, nil], matches([text, "", nil], "", mode)
    end
  end

  def test_uses_one_bound_page_batch_in_input_order_without_model_rows
    texts = ["North Rivendell", nil, "Moria", "Rivendell", "North Rivendell"]
    statements = capture_queries do
      assert_equal [texts[0], nil, nil, texts[3], texts[4]], matches(texts, "rivendell", :text_end)
    end
    batches = statements.select { |statement| statement.fetch(:sql).include?("jsonb_array_elements_text") }
    assert_equal 1, batches.length
    batch = batches.first
    assert_includes batch.fetch(:sql), "WITH ORDINALITY"
    assert_includes batch.fetch(:sql), "pg_catalog.pg_extension"
    refute_includes batch.fetch(:sql), "North Rivendell"
    assert_includes batch.fetch(:binds), JSON.generate(texts)
    refute statements.any? { |statement| statement.fetch(:sql).include?('FROM "tinkick_test_products"') }

    statements = capture_queries { assert_equal ["Rivendell", nil], matches(["Rivendell", "rivendell"], "Rivendell", :exact) }
    assert_equal 1, statements.length
    refute statements.any? { |statement| statement.fetch(:sql).include?("unaccent") }
  end

  def test_empty_batches_skip_sql_and_invalid_modes_fail_clearly
    statements = capture_queries do
      assert_equal [], matches([], "apple", :text_start)
      assert_equal [nil, nil], matches([nil, nil], "apple", :text_start)
    end
    assert_empty statements
    error = assert_raises(ArgumentError) { matches(["Apple"], "apple", :word) }
    assert_includes error.message, "Unsupported whole-field match mode"
  end

  private

  def matches(texts, term, mode, misspellings: false)
    Tinkick::TextMatch.new(SearchProduct).highlight_matches(texts, term, match: mode, misspellings: misspellings)
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
