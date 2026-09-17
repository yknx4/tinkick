# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/custom_spans"
require "tinkick/word_match"

class CustomSpansTest < Minitest::Test
  def test_preserved_case_rejects_default_analyzer_false_positives
    assert_equal [[[0, 6]]], locate(["FooBar foobar FOOBar"], ["FooBar"], case_folding: "preserve")
  end

  def test_preserved_accents_reject_unaccented_candidates_but_fold_case
    assert_equal [[[0, 8], [18, 26]]],
      locate(["Jalapeño jalapeno JALAPEÑO"], ["jalapeño"], accent_folding: "preserve")
  end

  def test_preserving_case_and_accents_accepts_only_the_original_token
    assert_equal [[[0, 8]]], locate(["Jalapeño jalapeno JALAPEÑO"], ["Jalapeño"],
      case_folding: "preserve", accent_folding: "preserve")
  end

  def test_accent_folding_does_not_override_preserved_case
    assert_equal [[[0, 5], [6, 11]]], locate(["Åpple Apple apple"], ["Apple"], case_folding: "preserve")
  end

  def test_case_expansion_maps_back_to_original_character_offsets
    source = "İ I i\u0307 i"

    assert_equal [[[0, 1], [4, 6]]], locate([source], ["i\u0307"], accent_folding: "preserve")
  end

  def test_accent_preservation_keeps_decomposed_and_composed_forms_distinct
    source = "café cafe\u0301 cafe"

    assert_equal [[[5, 10]]], locate([source], ["cafe\u0301"], accent_folding: "preserve")
  end

  def test_touching_spans_are_merged_only_after_each_token_is_verified
    # A combined native OR query merges the second word and emoji before the
    # case-preservation check, losing the independently eligible second emoji.
    assert_equal [[[0, 7], [14, 15]]],
      locate(["FooBar😀 foobar😀"], ["FooBar", "😀"], case_folding: "preserve")
  end

  def test_keycap_source_spans_keep_all_original_codepoints
    assert_equal [[[0, 3]]], locate(["*️⃣ #️⃣ * #"], ["*️⃣"], accent_folding: "preserve")
  end

  def test_merged_keycap_candidates_preserve_individual_variant_eligibility
    assert_equal [[[0, 3]]], locate(["*️⃣*⃣"], ["*️⃣"], accent_folding: "preserve")
    assert_equal [[[3, 5]]], locate(["*️⃣*⃣"], ["*⃣"], accent_folding: "preserve")
    assert_equal [[[0, 5]]], locate(["*️⃣*⃣"], ["*️⃣", "*⃣"], accent_folding: "preserve")
  end

  def test_whitespace_tokens_include_punctuation_that_unicode_analysis_drops
    assert_equal [[[1, 2], [11, 15], [16, 21]]],
      locate([" # $ . ( ) a(b) wi-fi "], ["#", "a(b)", "wi-fi"], tokenizer: "whitespace",
        case_folding: "preserve", accent_folding: "preserve")
  end

  def test_whitespace_boundaries_cover_every_unicode_white_space_character
    codepoints = [*(9..13), 0x20, 0x85, 0xA0, 0x1680, *(0x2000..0x200A), 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    sources = codepoints.map do |codepoint|
      space = codepoint.chr(Encoding::UTF_8)
      "#{space}A#{space}B#{space}"
    end

    assert_equal Array.new(sources.length) { [[1, 2]] }, locate(sources, ["A"],
      tokenizer: "whitespace", case_folding: "preserve", accent_folding: "preserve")
  end

  def test_non_whitespace_unicode_controls_stay_inside_whitespace_tokens
    [0x180E, 0x200B, 0xFEFF].each do |codepoint|
      token = "A#{codepoint.chr(Encoding::UTF_8)}B"
      analysis = { tokenizer: "whitespace", case_folding: "preserve", accent_folding: "preserve" }
      tokens = native_tokens(token, **analysis)

      refute_empty tokens, "U+#{codepoint.to_s(16)}"
      assert_equal [[[0, 3]]], locate(["#{token} A B"], tokens, **analysis)
    end
  end

  def test_whitespace_normalization_keeps_punctuation_and_original_expansion_spans
    assert_equal [[[0, 2], [6, 9]]], locate(["İ) I) i\u0307) i)"], ["i\u0307)"],
      tokenizer: "whitespace", accent_folding: "preserve")
    assert_equal [[[1, 3], [4, 7], [8, 15]]], locate([" e\u0301 *️⃣ 👨‍👩‍👧‍👦 "],
      ["e\u0301", "*️⃣", "👨‍👩‍👧‍👦"], tokenizer: "whitespace",
      case_folding: "preserve", accent_folding: "preserve")
  end

  def test_page_order_and_duplicate_tokens_preserve_one_span_set_per_input
    assert_equal [[[0, 6]], [], [], [], [[7, 13], [14, 20]]],
      locate(["FooBar", nil, "", "foobar", "before FooBar FooBar"],
        ["FooBar", "FooBar"], case_folding: "preserve")
  end

  def test_source_html_and_marker_collisions_do_not_change_offsets
    source = "\u0001tinkickstart\u0002 <b>FooBar</b> foobar \u0001tinkickend\u0002"
    start = source.index("FooBar")
    spans = locate([source], ["FooBar"], case_folding: "preserve")

    assert_equal [[[start, start + 6]]], spans
    assert_equal "FooBar", source[spans.fetch(0).fetch(0).first...spans.fetch(0).fetch(0).last]
  end

  def test_whitespace_literals_are_not_interpreted_as_sql_or_tinql
    token = "evil');--"
    source = "#{token} ordinary evil a.* aXb"

    assert_equal [[[0, token.length], [source.index("a.*"), source.index("a.*") + 3]]],
      locate([source], [token, "a.*"], tokenizer: "whitespace",
        case_folding: "preserve", accent_folding: "preserve")
  end

  def test_empty_inputs_skip_database_work
    ActiveRecord::Base.with_connection do |connection|
      locator = Tinkick::CustomSpans.new(connection)
      statements = []
      listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        assert_equal [], locator.locate([], tokens: ["FooBar"], analysis: analysis)
        assert_equal [[], []], locator.locate([nil, nil], tokens: ["FooBar"], analysis: analysis)
        assert_equal [[], []], locator.locate(["FooBar", nil], tokens: [], analysis: analysis)
      end
      assert_empty statements
    end
  end

  def test_custom_split_and_truncate_wait_for_precise_long_token_mapping
    ["split", "truncate"].each do |policy|
      error = assert_raises(ArgumentError) do
        locate(["abcdefghij"], ["abcd"], tokenizer: "whitespace", max_token_bytes: "4", long_tokens: policy)
      end

      assert_match(/source.span|mapping/i, error.message)
      refute_match(/not supported by TIN/i, error.message)
    end
  end

  def test_default_split_policy_does_not_mark_an_entire_long_source_token
    error = assert_raises(ArgumentError) do
      locate(["a" * 300], ["a" * 256], case_folding: "preserve")
    end

    assert_match(/source.span|mapping/i, error.message)
  end

  def test_candidate_and_verification_work_is_batched_and_uses_only_page_text
    small, small_statements = observed_locate(["FooBar foo"], ["FooBar"], case_folding: "preserve")
    source = "FooBar😀 foobar😀"
    large, large_statements = observed_locate(Array.new(16, source), ["FooBar", "😀"], case_folding: "preserve")

    assert_equal [[[0, 6]]], small
    assert_equal Array.new(16) { [[0, 7], [14, 15]] }, large
    assert_operator small_statements.length, :>, 0
    assert_equal small_statements.length, large_statements.length
    large_statements.each do |statement|
      sql = statement.fetch(:sql)
      refute_includes sql, "FooBar"
      refute_includes sql, "tinkick_test_products"
    end
  end

  private

  def locate(texts, tokens, **options)
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::CustomSpans.new(connection).locate(texts, tokens: tokens, analysis: analysis(**options))
    end
  end

  def observed_locate(texts, tokens, **options)
    statements = []
    listener = ->(*arguments) { statements << arguments.last.slice(:sql, :binds) }
    result = nil
    ActiveRecord::Base.with_connection do |connection|
      locator = Tinkick::CustomSpans.new(connection)
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        result = locator.locate(texts, tokens: tokens, analysis: analysis(**options))
      end
    end
    [result, statements]
  end

  def analysis(**options)
    Tinkick::WordMatch::ANALYSIS_DEFAULTS.merge(options.transform_keys(&:to_s))
  end

  def native_tokens(text, **options)
    ActiveRecord::Base.with_connection do |connection|
      arguments = analysis(**options).map do |name, value|
        ", #{name} => #{connection.quote(name == 'max_token_bytes' ? Integer(value, 10) : value)}"
      end.join
      connection.select_values(Arel.sql(<<~SQL, text)).map(&:to_s)
        SELECT tin.tokenize(?#{arguments}) FROM pg_catalog.pg_extension WHERE extname = 'tin'
      SQL
    end
  end
end
