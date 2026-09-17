# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/custom_spans"

class CustomPhraseSpansTest < Minitest::Test
  def test_whitespace_phrases_preserve_case_accents_and_complete_witnesses
    texts = ["Fëanor arrives fëanor arrives", "Fëanor waits arrives", "Feanor arrives"]

    assert_equal [[[0, 14]], [], []], locate(texts, "Fëanor arrives", tokenizer: "whitespace",
      case_folding: "preserve", accent_folding: "preserve")
  end

  def test_literal_punctuation_cannot_become_phrase_syntax
    options = { tokenizer: "whitespace", case_folding: "preserve" }

    assert_equal [[[5, 18]]], locate(['lead tag) "Quoted" tag) Quoted'], 'tag) "Quoted"', **options)
    assert_equal [[[0, 11]]], locate(["foo_bar [x] foo bar x"], "foo_bar [x]", **options)
    assert_equal [[], [[0, 7]]], locate(["aa xx bb", "aa _ bb"], "aa _ bb", **options)
  end

  def test_repeated_tokens_keep_overlapping_and_separate_phrase_occurrences
    assert_equal [[[0, 8]], [[0, 5], [9, 14]]], locate(["aa aa aa", "aa aa xx aa aa"], "aa aa",
      tokenizer: "whitespace")
  end

  def test_split_words_map_internal_fragments_and_analyze_the_query_identically
    options = { tokenizer: "whitespace", max_token_bytes: "4" }

    assert_equal [[[4, 10]]], locate(["abcdefghij"], "efgh ij", **options)
    assert_equal [[[0, 12]]], locate(["abcd efgh ij"], "abcdefghij", **options)
  end

  def test_truncated_tails_are_context_inside_a_multiword_phrase
    options = { tokenizer: "whitespace", max_token_bytes: "4", long_tokens: "truncate" }

    assert_equal [[[0, 13]], []], locate(["abcdefghij bb", "abcdefghij cc bb"], "abcd bb", **options)
    assert_equal [[[0, 4]]], locate(["abcdefghij bb"], "abcd", **options)
  end

  def test_internal_preserved_query_gaps_match_retained_or_discarded_words
    texts = ["aa cc bb", "aa toolong bb", "aa bb"]
    options = { tokenizer: "whitespace", max_token_bytes: "4", long_tokens: "discard" }

    assert_equal [[[0, 8]], [[0, 13]], []], locate(texts, "aa toolong bb", **options)
    assert_equal [[], [], [[0, 5]]], locate(texts, "aa bb", **options)
  end

  def test_collapsed_gaps_only_remove_discarded_source_tokens
    assert_equal [[], [[0, 13]], [[0, 5]]], locate(["aa cc bb", "aa toolong bb", "aa bb"], "aa toolong bb",
      tokenizer: "whitespace", max_token_bytes: "4", long_tokens: "discard", position_gaps: "collapse")
  end

  def test_leading_and_trailing_query_gaps_do_not_extend_the_witness
    texts = ["aa bb", "toolong aa bb", "aa bb toolong", "cc aa bb dd"]

    assert_equal [[[0, 5]], [[8, 13]], [[0, 5]], [[3, 8]]], locate(texts, "toolong aa bb toolong",
      tokenizer: "whitespace", max_token_bytes: "4", long_tokens: "discard")
  end

  def test_unicode_phrases_keep_case_and_accent_policy
    texts = ["Éowyn arrives éowyn arrives Eowyn arrives", "Eowyn arrives", "éowyn arrives"]

    assert_equal [[[0, 13]], [], []], locate(texts, "Éowyn arrives", case_folding: "preserve", accent_folding: "preserve")
    assert_equal [[[0, 13]]], locate(["Eowyn arrives"], "Éowyn arrives", case_folding: "preserve")
    assert_equal [[]], locate(["éowyn arrives"], "Éowyn arrives", case_folding: "preserve")
  end

  def test_unicode_symbol_filtering_does_not_create_a_preserved_gap
    assert_equal [[[0, 7]], []], locate(["aa $ bb", "aa-©-$-bb"], "aa bb", case_folding: "preserve")
    assert_equal [[[3, 9]]], locate(["aa-©-$-bb"], "© bb", case_folding: "preserve")
  end

  def test_unicode_case_expansion_and_ignored_combining_input_keep_original_offsets
    source = "İ i\u0307 I \u0301 bb"

    assert_equal [[[0, 4]]], locate([source], "İ i\u0307", accent_folding: "preserve")
    assert_equal [[[5, 11]]], locate([source], "I bb", accent_folding: "preserve")
  end

  def test_unicode_default_long_splitting_keeps_phrase_token_positions
    source = "#{'a' * 300} bb"

    assert_equal [[[256, 303]]], locate([source], "#{'a' * 44} bb", case_folding: "preserve")
    assert_equal [[[0, 303]]], locate([source], "#{'a' * 300} bb", case_folding: "preserve")
    assert_equal [[]], locate([source], "#{'a' * 256} bb", case_folding: "preserve")
  end

  def test_page_batches_preserve_null_positions_and_bind_only_supplied_text
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      assert_equal [[[0, 5]], [], [], []], locate(["aa bb", nil, "aa xx bb", "unrelated"], "aa bb", tokenizer: "whitespace")
    end

    refute_empty statements
    assert_operator statements.length, :<=, 4
    statements.each do |sql|
      refute_includes sql, "aa bb"
      refute_match(/tinkick_test_products|tin_text_cmpfunc_indexed|ql_parse/, sql)
    end
    assert_equal [[], []], locate([nil, "aa bb"], "")
    assert_equal [[]], locate(["aa bb"], "*")
  end

  def test_unicode_small_split_limits_map_complete_phrase_fragment_witnesses
    source = "aa-abcdefghij-bb"

    assert_equal [[[7, 16]]], locate([source], "efgh ij bb", max_token_bytes: "4")
    assert_equal [[]], locate([source], "abcd bb", max_token_bytes: "4")
  end

  def test_unicode_collapsed_discarded_terms_use_consecutive_stored_positions
    assert_equal [[[0, 16]], []], locate(["aa-abcdefghij-bb", "aa cc bb"], "aa bb",
      max_token_bytes: "4", long_tokens: "discard", position_gaps: "collapse")
    assert_equal [[[0, 16]]], locate(["aa-abcdefghij-bb"], "aa abcd bb",
      max_token_bytes: "4", long_tokens: "truncate", position_gaps: "collapse")
  end

  def test_unicode_grapheme_filtering_happens_before_phrase_position_counting
    source = "aa © $ 😀 *️⃣ bb"

    assert_equal [[[0, source.length]]], locate([source], "aa bb", graphemes: "discard")
    assert_equal [[[3, 8]]], locate([source], "© $ 😀", graphemes: "retain")
    assert_equal [[]], locate([source], "aa bb", graphemes: "retain")
  end

  def test_unicode_multibyte_split_phrases_keep_case_accent_and_source_offsets
    source = "aa ÉÉééX bb"
    options = { max_token_bytes: "4", case_folding: "preserve", accent_folding: "preserve" }

    assert_equal [[[5, 11]]], locate([source], "éé X bb", **options)
    assert_equal [[]], locate([source], "ÉÉ X bb", **options)
  end

  def test_unicode_split_keycap_tokens_share_the_original_source_grapheme
    source = "aa *️⃣*⃣ bb"

    assert_equal [[[3, 11]]], locate([source], "*️⃣*⃣ bb", max_token_bytes: "4", accent_folding: "preserve")
    assert_equal [[[6, 11]]], locate([source], "*⃣ bb", max_token_bytes: "4", accent_folding: "preserve")
  end

  def test_unicode_maximum_byte_limit_keeps_fragments_beyond_a_reference_token
    source = "#{'x' * 2700} bb"

    assert_equal [[[2692, 2703]]], locate([source], "#{'x' * 8} bb", max_token_bytes: "2692")
  end

  def test_unicode_normalization_can_shrink_a_source_grapheme_beyond_the_token_limit
    source = "a#{"\u0301" * 1500}tail bb"

    assert_equal [[[0, source.length]]], locate([source], "atai l bb", max_token_bytes: "4")
  end

  def test_unicode_preserved_discard_gaps_remain_explicit_until_reconstructed
    error = assert_raises(ArgumentError) do
      locate(["aa toolong bb"], "aa bb", max_token_bytes: "4", long_tokens: "discard")
    end

    assert_match(/phrase.*position|position.*phrase/i, error.message)
    refute_match(/not supported by TIN/i, error.message)
  end

  private

  def locate(texts, term, **options)
    analysis = Tinkick::WordMatch::ANALYSIS_DEFAULTS.merge(options.transform_keys(&:to_s))
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::CustomSpans.new(connection).locate_phrase(texts, term: term, analysis: analysis)
    end
  end
end
