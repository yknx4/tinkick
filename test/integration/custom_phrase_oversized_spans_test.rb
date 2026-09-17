# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/custom_spans"

class CustomPhraseOversizedSpansTest < Minitest::Test
  def test_truncated_hangul_letter_clusters_keep_one_missing_position
    ["\u1100", "\u1161", "\u11a8"].each do |letter|
      word = letter * 1000
      source = "aa #{word} bb"

      assert_equal [[[0, source.length]]], locate([source], source, long_tokens: "truncate")
      assert_equal [[]], locate([source], "aa bb", long_tokens: "truncate")
    end
  end

  def test_latin_letters_attached_to_a_hidden_grapheme_share_its_position
    source = "aa ab#{giant_jamo}cd bb"

    assert_equal [[[0, source.length]]], locate([source], "aa #{giant_jamo} bb")
    assert_equal [[]], locate([source], "aa cc #{giant_jamo} bb")
    assert_equal [[[0, source.length]]], locate([source], "aa ab bb", long_tokens: "truncate")
    assert_equal [[[3, 5]]], locate([source], "ab", long_tokens: "truncate")
  end

  def test_the_native_byte_limit_does_not_create_an_extra_word_boundary
    source = "aa #{'x' * 2692}#{giant_jamo} bb"

    assert_equal [[[0, source.length]]], locate([source], "aa #{giant_jamo} bb")
    assert_equal [[]], locate([source], "aa #{giant_jamo} #{giant_jamo} bb")
  end

  def test_adjacent_cjk_keeps_its_independent_native_word_position
    source = "aa 山#{giant_jamo} bb"

    assert_equal [[[0, source.length]]], locate([source], "aa 山 #{giant_jamo} bb")
    assert_equal [[[3, source.length]]], locate([source], "山 #{giant_jamo} bb")
    assert_equal [[]], locate([source], "aa #{giant_jamo} bb")
  end

  def test_hyphens_separate_hidden_words
    source = "aa #{giant_jamo}-#{giant_jamo} bb"

    assert_equal [[[0, source.length]]], locate([source], "aa #{giant_jamo} #{giant_jamo} bb")
    assert_equal [[]], locate([source], "aa #{giant_jamo} bb")
  end

  def test_internal_word_punctuation_joins_hidden_lexical_graphemes
    ["'", "’", ":", "_"].each do |separator|
      source = "aa #{giant_jamo}#{separator}#{giant_jamo} bb"

      assert_equal [[[0, source.length]]], locate([source], "aa #{giant_jamo} bb")
      assert_equal [[]], locate([source], "aa #{giant_jamo} #{giant_jamo} bb")
    end
  end

  def test_indic_conjuncts_keep_the_original_source_span
    source = "aa ab#{'क्' * 1000}कcd bb"

    assert_equal [[[0, source.length]]], locate([source], "aa #{giant_jamo} bb")
    assert_equal [[]], locate([source], "aa bb")
  end

  def test_oversized_emoji_does_not_gain_a_lexical_gap
    source = "aa 👩#{"\u200d👩" * 800} bb"

    assert_equal [[[0, source.length]]], locate([source], "aa bb")
    assert_equal [[]], locate([source], "aa #{giant_jamo} bb")
  end

  private

  def giant_jamo
    "\u1100" * 1000
  end

  def locate(texts, term, **options)
    analysis = Tinkick::WordMatch::ANALYSIS_DEFAULTS.merge("max_token_bytes" => "2692", "long_tokens" => "discard")
      .merge(options.transform_keys(&:to_s))
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::CustomSpans.new(connection).locate_phrase(texts, term: term, analysis: analysis)
    end
  end
end
