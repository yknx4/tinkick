# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/query_text"

class QueryTextTest < TinkickIntegrationTest
  def test_whole_words_use_and_by_default
    assert_equal(["Red Apple"], names("apple red"))
    assert_empty(names("apple pear"))
    assert_empty(names("app"))
  end

  def test_or_matches_any_word
    assert_equal(["Green Pear", "Red Apple"], names("apple pear", operator: "or"))
  end

  def test_word_start_matches_each_token_prefix
    assert_equal(["Red Apple"], names("app re", match: :word_start))
    assert_empty(names("ppl", match: :word_start))
    assert_empty(names("red pea", match: :word_start))
  end

  def test_word_middle_matches_within_each_token
    assert_equal(["Red Apple"], names("ppl ed", match: :word_middle))
    assert_empty(names("dapp", match: :word_middle))
    assert_empty(names("red pear", match: :word_middle))
  end

  def test_word_end_matches_each_token_suffix
    assert_equal(["Red Apple"], names("ple ed", match: :word_end))
    assert_empty(names("app", match: :word_end))
    assert_empty(names("ed ear", match: :word_end))
  end

  def test_partial_words_support_or_and_zero_edit_distance
    [:word_start, :word_middle, :word_end].each do |mode|
      assert_equal(["Green Pear", "Red Apple"], names("apple pear", match: mode, operator: "or"))
      assert_equal(["Red Apple"], names("apple", match: mode, misspellings: { edit_distance: 0 }))
      assert_empty(names("aplpe", match: mode, misspellings: { edit_distance: 0 }))
    end
  end

  def test_native_partial_words_have_no_elasticsearch_ngram_ceiling
    term = "𐐨" * 60
    tinkick_test_products(:red_apple).update!(name: term)

    [:word_start, :word_middle, :word_end].each do |mode|
      assert_equal([term], names("𐐨" * 50, match: mode))
      assert_equal([term], names("𐐨" * 51, match: mode))
      assert_empty(names("#{"𐐨" * 51} pear", match: mode))
      assert_equal(["Green Pear", term], names("#{"𐐨" * 51} pear", match: mode, operator: "or"))
    end
  end

  def test_partial_words_use_normalized_unicode_tokens
    tinkick_test_products(:red_apple).update!(name: "Jalapeño Wi-Fi foo_bar 😀")

    assert_equal(["Jalapeño Wi-Fi foo_bar 😀"], names("JALA FOO_ 😀", match: :word_start))
    assert_equal(["Jalapeño Wi-Fi foo_bar 😀"], names("LAP _BA 😀", match: :word_middle))
    assert_equal(["Jalapeño Wi-Fi foo_bar 😀"], names("PEÑO _BAR 😀", match: :word_end))
  end

  def test_partial_word_input_cannot_supply_query_syntax
    [:word_start, :word_middle, :word_end].each do |mode|
      assert_empty(names("*\"", match: mode))
      assert_empty(names("apple OR pear", match: mode))
      assert_empty(names("apple) OR (pear", match: mode))
      assert_empty(names("apple^10000", match: mode))
      assert_empty(names("apple~10000", match: mode))
      assert_empty(names("apple; SELECT * FROM tinkick_test_products --", match: mode))
      assert_equal(["Red Apple"], names("apple*?\\\\[]", match: mode))
    end
  end

  def test_partial_words_preserve_literal_keycaps
    tinkick_test_products(:red_apple).update!(name: "*️⃣ apple")
    tinkick_test_products(:green_pear).update!(name: "#️⃣ pear")

    [:word_start, :word_middle, :word_end].each do |mode|
      assert_equal(["*️⃣ apple"], names("*️⃣", match: mode))
      assert_equal(["#️⃣ pear"], names("#️⃣", match: mode))
      assert_equal(["#️⃣ pear", "*️⃣ apple"], names("*", match: mode).sort)
      assert_empty(names("!!!", match: mode))
    end
  end

  def test_only_a_standalone_star_matches_everything
    assert_equal(["Green Pear", "Red Apple"], names("*"))
    assert_equal(["Red Apple"], names("apple *"))
    assert_empty(names('"*"'))
  end

  def test_empty_and_punctuation_inputs_match_nothing
    ["", " \t\n", "!!!", '""', "[]", "\\", "_"].each do |term|
      assert_empty(names(term), term.inspect)
      assert_empty(names(term, match: :phrase), term.inspect)
    end
  end

  def test_query_operators_are_literal_words
    assert_empty(names("apple OR pear"))
    assert_empty(names("apple AND NOT pear"))
    assert_empty(names("apple; SELECT * FROM tinkick_test_products --"))

    product = tinkick_test_products(:red_apple)
    product.update!(name: "Apple OR Pear")

    assert_equal(["Apple OR Pear"], names("apple OR pear"))
  end

  def test_database_tokenization_preserves_accents_emoji_and_hyphens
    tinkick_test_products(:red_apple).update!(name: "Jalapeño 😀 Wi-Fi")

    assert_equal(["Jalapeño 😀 Wi-Fi"], names("JALAPENO 😀 wi-fi"))
    assert_equal(["Jalapeño 😀 Wi-Fi"], names("fi wi"))
  end

  def test_underscore_is_a_literal_part_of_a_word
    tinkick_test_products(:red_apple).update!(name: "foo_bar")

    assert_equal(["foo_bar"], names("foo_bar"))
    assert_equal(["foo_bar"], names("foo_bar", match: :phrase))
    assert_empty(names("foo bar"))
  end

  def test_keycap_emoji_remain_literal_dictionary_terms
    tinkick_test_products(:red_apple).update!(name: "*️⃣ apple")
    tinkick_test_products(:green_pear).update!(name: "#️⃣ pear")

    assert_equal(["*️⃣ apple"], names("*️⃣"))
    assert_equal(["#️⃣ pear"], names("#️⃣"))
    assert_equal(["*️⃣ apple"], names("*️⃣ apple"))
    assert_empty(names("*️⃣ pear"))
    assert_equal(["*️⃣ apple"], names("*️⃣", match: :phrase))
  end

  def test_phrase_requires_ordered_adjacent_words
    assert_equal(["Red Apple"], names("red apple", match: :phrase))
    assert_empty(names("apple red", match: :phrase))

    tinkick_test_products(:red_apple).update!(name: "Red Crisp Apple")

    assert_empty(names("red apple", match: :phrase))
    assert_empty(names("red _ apple", match: :phrase))
  end

  def test_phrase_brackets_cannot_add_alternatives
    tinkick_test_products(:red_apple).update!(name: "Big Bad Wolf")

    assert_empty(names("big [bad large] wolf", match: :phrase))
    assert_equal(["Big Bad Wolf"], names("big [bad] wolf", match: :phrase))
  end

  def test_phrase_quotes_and_backslashes_are_literal_input
    tinkick_test_products(:red_apple).update!(name: 'Red "Apple" \\ Orchard')

    assert_equal(['Red "Apple" \\ Orchard'], names('Red "Apple" \\ Orchard', match: :phrase))
    assert_empty(names('red" OR pear', match: :phrase))
  end

  def test_phrase_star_cannot_add_a_wildcard
    assert_empty(names("app*", match: :phrase))
    assert_equal(["Red Apple"], names("apple*", match: :phrase))
  end

  def test_unsupported_operators_and_modes_fail
    assert_raises(ArgumentError) { compile("apple", operator: "xor") }
    assert_raises(ArgumentError) { compile("apple", match: :unknown) }
  end

  def test_zero_distance_and_phrase_matching_remain_exact
    assert_equal(["Red Apple"], names("apple", misspellings: { edit_distance: 0 }))
    assert_empty(names("aplpe", misspellings: { edit_distance: 0 }))
    assert_equal(["Red Apple"], names("red apple", match: :phrase, misspellings: true))
    assert_empty(names("red aplpe", match: :phrase, misspellings: true))
  end

  def test_native_fuzzy_matching_defaults_to_one_edit
    assert_equal(["Red Apple"], names("appl", misspellings: { transpositions: false }))
    assert_empty(names("aplpe", misspellings: { transpositions: false }))
    assert_empty(names("app", misspellings: { transpositions: false }))
  end

  def test_native_fuzzy_distance_and_distance_alias
    assert_equal(["Red Apple"], names("aplpe", misspellings: { transpositions: false, edit_distance: 2 }))
    assert_equal(["Red Apple"], names("aplpe", misspellings: { transpositions: false, distance: 2 }))
    assert_empty(names("appl", misspellings: { transpositions: false, edit_distance: 0 }))
  end

  def test_native_fuzzy_prefix_length
    assert_equal(["Red Apple"], names("pple", misspellings: { transpositions: false, prefix_length: 0 }))
    assert_empty(names("pple", misspellings: { transpositions: false, prefix_length: 1 }))
  end

  def test_fuzzy_operators_apply_to_individual_native_tokens
    assert_equal(["Red Apple"], names("ryd-appl", misspellings: { transpositions: false }))
    assert_equal(["Red Apple"], names("appl zzzzz", operator: "or", misspellings: { transpositions: false }))
    assert_empty(names("appl zzzzz", misspellings: { transpositions: false }))
    assert_empty(names("appl OR pear", misspellings: { transpositions: false }))
    assert_empty(names("apple^10000 OR pear", misspellings: { transpositions: false }))
  end

  def test_fuzzy_matching_handles_literal_underscores_apostrophes_and_unicode
    tinkick_test_products(:red_apple).update!(name: "foo_bar O'Reilly Jalapeño 😀")

    assert_equal(["foo_bar O'Reilly Jalapeño 😀"], names("foo_baz o'reill jalapeno 😀", misspellings: { transpositions: false }))
  end

  def test_phrase_matching_does_not_apply_fuzzy_edits
    assert_equal(["Red Apple"], names("red apple", match: :phrase, misspellings: { transpositions: false }))
    assert_empty(names("red appl", match: :phrase, misspellings: { transpositions: false }))
  end

  def test_fuzzy_keycaps_match_literal_dictionary_terms_within_the_edit_distance
    tinkick_test_products(:red_apple).update!(name: "*️⃣")
    tinkick_test_products(:green_pear).update!(name: "#️⃣")

    [true, { transpositions: false }].each do |options|
      assert_equal(["*️⃣"], names("*️⃣", misspellings: options))
      assert_equal(["#️⃣"], names("#️⃣", misspellings: options))
    end
    assert_equal(["#️⃣", "*️⃣"], names("*️⃣", misspellings: { prefix_length: 0 }).sort)
    assert_equal(["#️⃣", "*️⃣"], names("#️⃣", misspellings: { prefix_length: 0 }).sort)
  end

  def test_fuzzy_keycaps_honor_prefix_and_zero_distance_controls
    tinkick_test_products(:red_apple).update!(name: "*️⃣")
    tinkick_test_products(:green_pear).update!(name: "#️⃣")

    assert_equal(["*️⃣"], names("*️⃣", misspellings: { prefix_length: 1 }))
    assert_equal(["#️⃣"], names("#️⃣", misspellings: { edit_distance: 0 }))
  end

  def test_fuzzy_keycaps_cannot_expand_into_unrelated_long_dictionary_terms
    tinkick_test_products(:red_apple).update!(name: "*️⃣ fruit")

    assert_equal(["*️⃣ fruit"], names("*️⃣", misspellings: true))
    assert_equal(["*️⃣ fruit"], names("*️⃣ fruut", misspellings: true))
    assert_empty(names("*️⃣ pear", misspellings: true))
    assert_equal(["*️⃣ fruit", "Green Pear"], names("*️⃣ pear", operator: "or", misspellings: true).sort)
  end

  def test_empty_and_match_all_preserve_their_meaning_with_misspellings
    assert_empty(names("!!!", misspellings: { transpositions: false }))
    assert_equal(["Green Pear", "Red Apple"], names("*", misspellings: { transpositions: false }))
  end

  def test_fuzzy_matching_preserves_native_scores_and_eligibility
    tinkick_test_products(:red_apple).update!(name: "Apple")
    tinkick_test_products(:green_pear).update!(name: "Apples")
    query = compile("apple", misspellings: { transpositions: false })
    matches = SearchProduct.where("name ==> ?", query)
      .order(:name).pluck(:name, Arel.sql("tin.score(ctid)"))
    native_matches = SearchProduct.where("name ==> ?", "apple~1")
      .order(:name).pluck(:name, Arel.sql("tin.score(ctid)"))

    assert_equal(["Apple", "Apples"], matches.map(&:first))
    assert_equal(native_matches, matches)
  end

  def test_plain_words_use_native_analysis_without_tokenize_round_trips
    tinkick_test_products(:red_apple).update!(name: "Jalapeño Wi-Fi foo_bar NASA Apple")
    statements = capture_statements do
      assert_equal(["Jalapeño Wi-Fi foo_bar NASA Apple"], names("JALAPENO, (nasa) apple!", misspellings: false))
      assert_equal(["Jalapeño Wi-Fi foo_bar NASA Apple"], names("Jalapenos NASA", misspellings: true))
      assert_equal(["Jalapeño Wi-Fi foo_bar NASA Apple"], names("JALA FOO_", match: :word_start))
      assert_equal(["Jalapeño Wi-Fi foo_bar NASA Apple"], names("LAP _BA", match: :word_middle))
      assert_equal(["Jalapeño Wi-Fi foo_bar NASA Apple"], names("PEÑO _BAR", match: :word_end))
      assert_equal(["Green Pear"], names("pear AND NOT", operator: "or", misspellings: true))
      assert_empty(names("apple TO", misspellings: true))
      assert_empty(names("!!! _", misspellings: true))
    end

    assert_empty(statements.grep(/tin\.tokenize/))
  end

  def test_word_start_uses_native_term_ranges_for_every_completion
    tinkick_test_products(:red_apple).update!(name: "Toé tò𐐨𐐨 tom\u{1F189} to\u{1FBF9}x ANDES")

    assert_match(/\Ato TO to\u{1FBF9}+\z/, compile("to", match: :word_start))
    refute_match(/[*]|MATCHES/, compile("TO AND", match: :word_start))
    assert_equal([tinkick_test_products(:red_apple).name], names("TO AND", match: :word_start))
    assert_equal([tinkick_test_products(:red_apple).name], names("tò", match: :word_start))
    assert_empty(names("toez", match: :word_start))
  end

  def test_keycap_literals_use_native_phrases
    refute_includes(compile("*️⃣ #️⃣"), "MATCHES")
    refute_includes(compile("*️⃣", match: :word_start), "MATCHES")
  end

  def test_invalid_native_fuzzy_options_fail
    [
      { edit_distance: -1 }, { edit_distance: "1" }, { distance: 1.5 },
      { prefix_length: -1 }, { prefix_length: "0" },
      { below: 5 }, { fields: [:name] }, { unknown: true },
    ].each do |options|
      assert_raises(ArgumentError) do
        compile("apple", misspellings: options.merge(transpositions: false))
      end
    end
  end

  private

  def compile(term, **options)
    Tinkick::QueryText.new(SearchProduct.connection).compile(term, **options)
  end

  def capture_statements
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  def names(term, **options)
    SearchProduct.where("name ==> ?", compile(term, **options)).order(:name).pluck(:name)
  end
end
