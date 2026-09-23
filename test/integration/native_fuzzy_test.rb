# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/query_text"
require_relative "../../lib/tinkick/text_match"

class NativeFuzzyTest < TinkickIntegrationTest
  def test_default_fuzzy_matching_uses_native_levenshtein_without_generated_swaps
    compiler = Tinkick::QueryText.new(SearchProduct.connection)
    %w[applf applle appel].each do |term|
      actual = SearchProduct.where("name ==> ?", compiler.compile(term, misspellings: true)).order(:id).pluck(:id)
      native = SearchProduct.where("name ==> ?", "#{term}~1").order(:id).pluck(:id)
      assert_equal(native, actual, term)
    end
  end

  def test_native_two_edit_distance_and_fixed_prefix_are_available
    compiler = Tinkick::QueryText.new(SearchProduct.connection)
    actual = compiler.compile("papel", misspellings: { edit_distance: 2 })
    assert_equal("papel~2", actual)
    assert_equal(SearchProduct.where("name ==> ?", "papel~2").pluck(:id), SearchProduct.where("name ==> ?", actual).pluck(:id))
    assert_equal("apple~3:2", compiler.compile("apple", misspellings: { edit_distance: 2, prefix_length: 3 }))
  end

  def test_explicit_transpositions_are_rejected_and_false_uses_native_matching
    compiler = Tinkick::QueryText.new(SearchProduct.connection)
    error = assert_raises(Tinkick::NotImplementedError) do
      compiler.compile("appel", misspellings: { transpositions: true })
    end
    assert_includes(error.message, "TIN")
    assert_equal("appel~1", compiler.compile("appel", misspellings: { transpositions: false }))
  end

  def test_explicit_elasticsearch_expansion_caps_are_rejected
    error = assert_raises(Tinkick::NotImplementedError) do
      Tinkick::QueryText.new(SearchProduct.connection).compile("apple", misspellings: { max_expansions: 3 })
    end
    assert_includes(error.message, "max_expansions")
    assert_includes(error.message, "TIN")
  end

  def test_whole_field_fuzzy_matching_does_not_install_an_emulated_distance_engine
    error = assert_raises(Tinkick::NotImplementedError) do
      Tinkick::TextMatch.new(SearchProduct).predicate('"name"', "appl", match: :text_start, misspellings: true)
    end
    assert_includes(error.message, "TIN")
    assert_includes(error.message, "misspellings: false")
  end

  def test_native_wildcards_do_not_claim_fuzzy_prefix_or_suffix_matching
    compiler = Tinkick::QueryText.new(SearchProduct.connection)
    [:word_start, :word_middle, :word_end].each do |mode|
      error = assert_raises(Tinkick::NotImplementedError) { compiler.compile("appl", match: mode, misspellings: true) }
      assert_includes(error.message, "misspellings: false")
    end
  end

  def test_native_fuzzy_tokens_with_quoted_delimiters_fail_clearly
    compiler = Tinkick::QueryText.new(SearchProduct.connection)
    error = assert_raises(Tinkick::NotImplementedError) do
      compiler.compile('a"b', misspellings: true, analysis: { "tokenizer" => "whitespace" })
    end
    assert_includes(error.message, "Native TIN")
    assert_includes(error.message, "misspellings: false")
  end
end
