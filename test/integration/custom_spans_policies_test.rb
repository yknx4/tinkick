# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/custom_spans"
require "tinkick/word_match"

class CustomSpansPoliciesTest < Minitest::Test
  def test_smaller_split_limits_map_only_the_matching_fragment
    assert_equal [[[4, 8]]], locate(["abcdefghij"], ["efgh"], max_token_bytes: "4")
    assert_equal [[[0, 4], [8, 10]]], locate(["abcdefghij"], ["abcd", "ij"], max_token_bytes: "4")
    assert_equal [[[0, 10]]], locate(["abcdefghij"], ["abcd", "efgh", "ij"], max_token_bytes: "4")
  end

  def test_default_limit_splits_original_long_words_without_overhighlighting
    source = "a" * 300

    assert_equal [[[0, 256]]], locate([source], ["a" * 256])
    assert_equal [[[256, 300]]], locate([source], ["a" * 44])
    assert_equal [[[0, 300]]], locate([source], ["a" * 256, "a" * 44])
  end

  def test_larger_limits_preserve_a_long_word_as_one_token
    source = "a" * 300

    assert_equal [[[0, 300]]], locate([source], [source], max_token_bytes: "1024")
    assert_equal [[]], locate([source], ["a" * 256], max_token_bytes: "1024")
  end

  def test_truncation_marks_the_stored_prefix_and_keeps_raw_tails_unmarked
    assert_equal [[[0, 4]]], locate(["abcdefghij"], ["abcd"], max_token_bytes: "4", long_tokens: "truncate")
    assert_equal [[]], locate(["abcdefghij"], ["efgh"], max_token_bytes: "4", long_tokens: "truncate")
    assert_equal [[[0, 4], [9, 13]]], locate(["abcdLONG-abcd"], ["abcd"], max_token_bytes: "4", long_tokens: "truncate")
  end

  def test_discard_does_not_map_a_matching_transient_prefix_of_a_removed_token
    assert_equal [[[9, 13]]], locate(["abcdLONG-abcd"], ["abcd"], max_token_bytes: "4", long_tokens: "discard")
    assert_equal [[[9, 13]]], locate(["abcdLONG abcd"], ["abcd"], tokenizer: "whitespace",
      max_token_bytes: "4", long_tokens: "discard")
    assert_equal [[]], locate(["abcdLONG"], ["abcd"], max_token_bytes: "4", long_tokens: "discard")
  end

  def test_byte_limits_keep_character_offsets_for_multibyte_source
    assert_equal [[[0, 4]]], locate(["ééééx"], ["éé"], max_token_bytes: "4", accent_folding: "preserve")
    assert_equal [[[4, 5]]], locate(["ééééx"], ["x"], max_token_bytes: "4", accent_folding: "preserve")
  end

  def test_case_expansion_is_mapped_to_its_original_graphemes
    options = { tokenizer: "whitespace", max_token_bytes: "4", accent_folding: "preserve" }

    assert_equal [[[0, 2]]], locate(["İİİ)"], ["i\u0307"], **options)
    assert_equal [[[2, 4]]], locate(["İİİ)"], ["i\u0307)"], **options)
    assert_equal [[[0, 1]]], locate(["İİİ)"], ["i\u0307"], **options, long_tokens: "truncate")
  end

  def test_multiple_stored_tokens_can_share_one_original_grapheme
    options = { max_token_bytes: "4", accent_folding: "preserve" }

    assert_equal [[[0, 3]]], locate(["*️⃣*⃣"], ["*️"], **options)
    assert_equal [[[0, 3]]], locate(["*️⃣*⃣"], ["⃣"], **options)
    assert_equal [[[3, 5]]], locate(["*️⃣*⃣"], ["*⃣"], **options)
    assert_equal [[[3, 5]]], locate(["*️⃣*⃣"], ["*⃣"], **options, long_tokens: "truncate")
    assert_equal [[[3, 5]]], locate(["*️⃣*⃣"], ["*⃣"], **options, long_tokens: "discard")
  end

  def test_retained_graphemes_include_symbols_that_default_highlighting_omits
    assert_equal [[[3, 4], [9, 10]]], locate(["aa © ☃ # $ bb"], ["©", "$"], graphemes: "retain")
    assert_equal [[[1, 3]]], locate(["©$☃😀"], ["$", "☃"], graphemes: "retain")
  end

  def test_discarded_graphemes_never_create_spans
    source = "aa © ☃ # $ 😀 *️⃣ bb"

    assert_equal [[]], locate([source], ["©", "$", "😀", "*"], graphemes: "discard")
    assert_equal [[[17, 19]]], locate([source], ["bb"], graphemes: "discard")
  end

  def test_native_word_boundary_lookahead_is_not_included_in_the_previous_fragment
    source = "can't.foo-a_b 3.14 カタカナ中文"
    options = { max_token_bytes: "4", graphemes: "retain" }

    assert_equal [[[0, 4]]], locate([source], ["can'"], **options)
    assert_equal [[[4, 8]]], locate([source], ["t.fo"], **options)
    assert_equal [[[19, 20], [21, 22]]], locate([source], ["カ"], **options)
  end

  def test_normalization_can_shrink_an_oversized_source_grapheme
    source = "a" + "\u0301" * 1_500 + "tail"

    assert_equal [[[0, 1_504]]], locate([source], ["atai"], max_token_bytes: "4")
    assert_equal [[[1_504, 1_505]]], locate([source], ["l"], max_token_bytes: "4")
  end

  def test_position_gap_policy_does_not_change_nonphrase_source_offsets
    options = { max_token_bytes: "4", long_tokens: "discard", position_gaps: "collapse" }

    assert_equal [[[9, 13]]], locate(["abcdLONG-abcd"], ["abcd"], **options)
  end

  def test_policy_mapping_preserves_page_positions_and_binds_source_values
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      assert_equal [[[4, 8]], [], [], []], locate(["abcdefghij", nil, "", "unrelated"], ["efgh"], max_token_bytes: "4")
    end

    refute_empty statements
    statements.each do |sql|
      refute_includes sql, "abcdefghij"
      refute_includes sql, "tinkick_test_products"
    end
  end

  private

  def locate(texts, tokens, **options)
    analysis = Tinkick::WordMatch::ANALYSIS_DEFAULTS.merge(options.transform_keys(&:to_s))
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::CustomSpans.new(connection).locate(texts, tokens: tokens, analysis: analysis)
    end
  end
end
