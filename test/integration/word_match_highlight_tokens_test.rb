# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/word_match"

class WordMatchHighlightTokensTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  class PreserveNameAnalysis < ActiveRecord::Migration[8.0]
    def up
      remove_index(:tinkick_test_products, :name, using: :tin)
      execute(<<~SQL)
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (tokenizer = whitespace, case_folding = preserve, accent_folding = preserve)
      SQL
    end

    def down
      remove_index(:tinkick_test_products, :name, using: :tin)
      add_index(:tinkick_test_products, :name, using: :tin)
    end
  end

  class RemoveOptionalHighlightHelpers < ActiveRecord::Migration[8.0]
    def up
      execute "DROP FUNCTION tinkick.edit_distance(text,text,integer,boolean) RESTRICT"
      execute "DROP FUNCTION tinkick.osa_distance(text,text,integer) RESTRICT"
      execute "DROP EXTENSION fuzzystrmatch RESTRICT"
    end
  end

  teardown do
    Product.reset_column_information
  end

  def test_returns_unique_analyzed_page_tokens_for_exact_matches
    texts = ["APPLE red apple pear", nil, "Jalapeño", "Distant hillside"]

    assert_equal ["apple"], tokens("apple", texts)
    assert_equal ["apple"], tokens("apple", texts, misspellings: { edit_distance: 0 })
    assert_equal ["jalapeno"], tokens("jalapeno", texts)
    assert_equal ["*"], tokens("*️⃣", ["*️⃣ #️⃣"])
  end

  def test_custom_analysis_preserves_case_accents_and_whitespace_punctuation
    with_preserved_analysis do
      texts = ["FooBar foobar JALAPEÑO Jalapeño jalapeno a(b) ab # evil');--"]

      assert_equal ["FooBar", "Jalapeño", "a(b)"], tokens("FooBar Jalapeño a(b)", texts)
      assert_equal ["#"], tokens("#", texts)
      assert_equal ["evil');--"], tokens("evil');--", texts)
      assert_equal ["a(b)"], tokens("a(b)", texts, misspellings: { edit_distance: 0, prefix_length: 2 })
    end
  end

  def test_exact_partials_return_the_complete_eligible_page_token
    { word_start: ["appletree", "xappletree"], word_middle: ["pineappletree", "plum"], word_end: ["pineapple", "pineapplex"] }.each do |mode, (matched, control)|
      texts = [matched, control, nil]
      assert_equal [matched], tokens("apple", texts, match: mode), mode.to_s
      assert_equal [matched], tokens("apple", texts, match: mode, misspellings: { edit_distance: 0 }), mode.to_s
    end
  end

  def test_one_edit_partial_transpositions_and_fixed_prefixes
    { word_start: "appletree", word_middle: "zzapplezz", word_end: "zzapple" }.each do |mode, text|
      assert_equal [text], tokens("aplpe", [text, "distant"], match: mode, misspellings: true), mode.to_s
      assert_empty tokens("aplpe", [text], match: mode, misspellings: { transpositions: false }), mode.to_s
      assert_equal [text], tokens("aplpe", [text], match: mode, misspellings: { prefix_length: 2 }), mode.to_s
      assert_empty tokens("aplpe", [text], match: mode, misspellings: { prefix_length: 3 }), mode.to_s
    end
  end

  def test_two_edit_partials_keep_prefix_and_transposition_controls
    { word_start: "appletree", word_middle: "zzapplezz", word_end: "zzapple" }.each do |mode, text|
      assert_equal [text], tokens("papel", [text, "distant"], match: mode, misspellings: { edit_distance: 2 }), mode.to_s
      assert_empty tokens("papel", [text], match: mode, misspellings: { edit_distance: 2, prefix_length: 3 }), mode.to_s
      # "appl" needs two edits, and "ppl" two deletions, even without swaps.
      expected_without_swaps = mode == :word_end ? [] : [text]
      assert_equal expected_without_swaps, tokens("papel", [text], match: mode,
        misspellings: { edit_distance: 2, transpositions: false }), mode.to_s
    end
  end

  def test_gram_ceiling_applies_at_zero_one_and_two_edits
    text = "a" * 50 + "suffix"
    [0, 1, 2].each do |distance|
      options = { edit_distance: distance, transpositions: false }

      assert_equal [text], tokens("a" * (50 + distance), [text], match: :word_start, misspellings: options)
      assert_empty tokens("a" * (51 + distance), [text], match: :word_start, misspellings: options)
    end
    assert_empty tokens("a" * 52, [text], match: :word_start, misspellings: { edit_distance: 2, prefix_length: 51 })
  end

  def test_one_edit_whole_words_keep_transposition_and_prefix_controls
    texts = ["apple aplpe pear"]

    assert_equal ["aplpe", "apple"], tokens("aplpe", texts, misspellings: true)
    assert_equal ["aplpe"], tokens("aplpe", texts, misspellings: { transpositions: false })
    assert_equal ["aplpe"], tokens("aplpe", texts, misspellings: { prefix_length: 3 })
  end

  def test_fuzzy_custom_tokens_use_the_index_analysis
    with_preserved_analysis do
      assert_equal ["FooBar", "FooBat"], tokens("FooBar", ["FooBar FooBat foobar fooBat"], misspellings: true)
      assert_equal ["a(b)"], tokens("ab()", ["a(b) unrelated"], misspellings: true)
      assert_empty tokens("ab()", ["a(b) unrelated"], misspellings: { transpositions: false })
      assert_equal ["leada(b)tail"], tokens("ab()", ["leada(b)tail", "distant"], match: :word_middle, misspellings: true)
    end
  end

  def test_exact_highlighting_does_not_require_optional_functions_or_extensions
    capture_io { RemoveOptionalHighlightHelpers.new.migrate(:up) }
    assert_raises(Tinkick::Error) { Tinkick::Functions.require!(Product) }
    assert_raises(Tinkick::Error) { Tinkick::Functions.require_edit_distance!(Product) }
    refute Product.connection.extension_enabled?("fuzzystrmatch")

    assert_equal ["apple"], tokens("apple", ["Apple pear"])
    assert_equal ["appletree"], tokens("apple", ["appletree"], match: :word_start)
    assert_equal ["pineapple"], tokens("apple", ["pineapple"], match: :word_end, misspellings: { edit_distance: 0 })
  end

  def test_empty_inputs_and_unmatched_tokens_return_an_empty_array
    assert_equal [], tokens("apple", [])
    assert_equal [], tokens("apple", [nil, nil])
    assert_equal [], tokens("", ["Apple"])
    assert_equal [], tokens("apple", ["Distant hillside"])
  end

  def test_existing_highlight_query_remains_a_literal_matches_wrapper
    texts = ["apple aplpe pear"]
    helper = Tinkick::WordMatch.new(Product)
    expected = helper.highlight_tokens("name", "aplpe", texts: texts, match: :word, misspellings: true)
      .map { |token| "(MATCHES #{Regexp.escape(token)})" }.join(" OR ")

    assert_equal expected, helper.highlight_query("name", "aplpe", texts: texts, match: :word, misspellings: true)
  end

  def test_exact_page_eligibility_uses_one_bound_batch_without_loading_model_rows
    tokens("apple", ["Apple"])
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      assert_equal ["apple"], tokens("apple", ["Apple", nil, "Pear", "Apple Apple"])
    end

    assert_equal 1, statements.length
    assert_includes statements.first, "jsonb_array_elements_text"
    refute_includes statements.first, "Apple"
    refute_includes statements.first, 'FROM "tinkick_test_products"'
    refute_includes statements.first, "osa_distance"
    refute_includes statements.first, "edit_distance"
    refute_includes statements.first, "levenshtein"
  end

  private

  def tokens(term, texts, match: :word, misspellings: false)
    Tinkick::WordMatch.new(Product).highlight_tokens("name", term, texts: texts, match: match, misspellings: misspellings)
  end

  def with_preserved_analysis
    migration = PreserveNameAnalysis.new
    capture_io { migration.migrate(:up) }
    Product.reset_column_information
    yield
  ensure
    capture_io { migration.migrate(:down) }
    Product.reset_column_information
  end
end
