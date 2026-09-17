# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/custom_spans"

class CustomPhraseGapSpansTest < Minitest::Test
  def test_discarded_unicode_words_preserve_positions_inside_one_source_run
    source = "aa-longone-cc-longtwo-bb"

    assert_equal [[[0, source.length]]], locate([source], "aa toolong cc toolong bb")
    assert_equal [[]], locate([source], "aa cc bb")
  end

  def test_preserved_query_gaps_can_match_retained_source_words
    assert_equal [[[0, 8]], []], locate(["aa cc bb", "aa bb"], "aa toolong bb")
  end

  def test_grapheme_filtering_does_not_add_extra_long_token_gaps
    source = "aa © abcdefghij $ 😀 bb"

    assert_equal [[[0, source.length]]], locate([source], "aa toolong bb", graphemes: "discard")
    assert_equal [[]], locate([source], "aa bb", graphemes: "discard")
  end

  def test_regular_truncation_keeps_one_position_and_original_internal_tails
    source = "aa-abcdefghij-bb"

    assert_equal [[[0, source.length]]], locate([source], "aa abcd bb", long_tokens: "truncate")
    assert_equal [[[3, 7]]], locate([source], "abcd", long_tokens: "truncate")
  end

  def test_truncation_of_an_oversized_grapheme_preserves_its_missing_position
    source = "aa *️⃣*⃣ bb"
    options = { long_tokens: "truncate", accent_folding: "preserve" }

    assert_equal [[[0, source.length]]], locate([source], "aa *️⃣*⃣ bb", **options)
    assert_equal [[]], locate([source], "aa *⃣ bb", **options)
    assert_equal [[[6, 11]]], locate([source], "*⃣ bb", **options)
  end

  def test_folded_keycaps_are_reanalyzed_from_the_original_source
    source = "aa *️⃣*⃣ bb"

    assert_equal [[[0, source.length]]], locate([source], "aa *️⃣*⃣ bb")
    assert_equal [[]], locate([source], "aa bb")
  end

  def test_query_edge_gaps_do_not_extend_source_witnesses
    assert_equal [[[8, 13]], [[3, 8]]], locate(["toolong aa bb toolong", "cc aa bb dd"], "toolong aa bb toolong")
  end

  def test_discarded_words_above_the_maximum_reference_width_keep_a_gap
    source = "aa #{'x' * 2700} bb"
    query = "aa #{'q' * 2700} bb"

    assert_equal [[[0, source.length]]], locate([source], query, max_token_bytes: "2692")
    assert_equal [[]], locate([source], "aa bb", max_token_bytes: "2692")
  end

  def test_multiple_huge_combining_words_keep_distinct_positions_before_folding
    huge = "a#{"\u0301" * 1500}tail"
    source = "aa #{huge}-#{huge} bb"
    options = { max_token_bytes: "2692", accent_folding: "preserve" }

    assert_equal [[[0, source.length]]], locate([source], "aa #{huge} #{huge} bb", **options)
    assert_equal [[]], locate([source], "aa #{huge} bb", **options)
    assert_equal [[]], locate([source], "aa bb", **options, long_tokens: "truncate")
  end

  def test_hidden_oversized_lexical_boundaries_fail_before_returning_false_witnesses
    source = "aa #{"\u1100" * 1000} bb"
    error = assert_raises(ArgumentError) { locate([source], "aa bb", max_token_bytes: "2692") }

    assert_match(/oversized lexical graphemes/, error.message)
    refute_match(/not supported by TIN/i, error.message)
  end

  private

  def locate(texts, term, **options)
    analysis = Tinkick::WordMatch::ANALYSIS_DEFAULTS.merge("max_token_bytes" => "4", "long_tokens" => "discard")
      .merge(options.transform_keys(&:to_s))
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::CustomSpans.new(connection).locate_phrase(texts, term: term, analysis: analysis)
    end
  end
end
