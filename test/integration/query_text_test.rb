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

  def test_fuzzy_matching_defaults_to_one_edit_including_transpositions
    [true, {}, { edit_distance: 1 }, { transpositions: true }].each do |option|
      assert_equal(["Red Apple"], names("aplpe", misspellings: option))
      assert_equal(["Red Apple"], names("appl", misspellings: option))
    end
  end

  def test_transpositions_do_not_combine_with_another_edit
    tinkick_test_products(:green_pear).update!(name: "Apples")

    assert_equal(["Red Apple"], names("aplpe", misspellings: true))
  end

  def test_transpositions_preserve_the_required_prefix
    assert_equal(["Red Apple"], names("aplpe", misspellings: { prefix_length: 2 }))
    assert_empty(names("aplpe", misspellings: { prefix_length: 3 }))
  end

  def test_transpositions_use_unicode_codepoints_and_literal_dictionary_terms
    tinkick_test_products(:red_apple).update!(name: "a𐐨b foo_ab")

    assert_equal(["a𐐨b foo_ab"], names("ab𐐨 foo_ba", misspellings: true))
    assert_equal(["a𐐨b foo_ab"], names("ab𐐨", misspellings: { prefix_length: 1 }))
    assert_empty(names("ab𐐨", misspellings: { prefix_length: 2 }))
  end

  def test_transpositions_group_alternatives_for_each_word
    assert_equal(["Red Apple"], names("erd aplpe", misspellings: true))
    assert_empty(names("erd zzzzz", misspellings: true))
    assert_equal(["Red Apple"], names("aplpe zzzzz", operator: "or", misspellings: true))
    assert_empty(names("aplpe OR pear", misspellings: true))
  end

  def test_transpositions_preserve_zero_distance_and_phrase_matching
    assert_equal(["Red Apple"], names("apple", misspellings: { edit_distance: 0 }))
    assert_empty(names("aplpe", misspellings: { edit_distance: 0 }))
    assert_equal(["Red Apple"], names("red apple", match: :phrase, misspellings: true))
    assert_empty(names("red aplpe", match: :phrase, misspellings: true))
  end

  def test_transpositions_at_larger_distances_fail_explicitly
    error = assert_raises(ArgumentError) { compile("apple", misspellings: { edit_distance: 2 }) }

    assert_includes(error.message, "transpositions")
    assert_includes(error.message, "transpositions: false")
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

  def test_fuzzy_keycaps_require_a_source_preserving_translation
    ["*️⃣", "#️⃣"].each do |term|
      [true, { transpositions: false }].each do |options|
        error = assert_raises(ArgumentError) do
          compile(term, misspellings: options)
        end

        assert_includes(error.message, "keycap")
        assert_includes(error.message, "misspellings: false")
      end
    end
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
    native_matches = SearchProduct.where("name ==> ?", "apple~0:1")
      .order(:name).pluck(:name, Arel.sql("tin.score(ctid)"))

    assert_equal(["Apple", "Apples"], matches.map(&:first))
    assert_equal(native_matches, matches)
  end

  def test_invalid_native_fuzzy_options_fail
    [
      { edit_distance: -1 }, { edit_distance: "1" }, { distance: 1.5 },
      { prefix_length: -1 }, { prefix_length: "0" },
      { max_expansions: 3 }, { below: 5 }, { fields: [:name] }, { unknown: true },
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

  def names(term, **options)
    SearchProduct.where("name ==> ?", compile(term, **options)).order(:name).pluck(:name)
  end
end
