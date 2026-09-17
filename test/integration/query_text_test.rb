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
    assert_raises(ArgumentError) { compile("apple", misspellings: true) }
  end

  private

  def compile(term, **options)
    Tinkick::QueryText.new(SearchProduct.connection).compile(term, **options)
  end

  def names(term, **options)
    SearchProduct.where("name ==> ?", compile(term, **options)).order(:name).pluck(:name)
  end
end
