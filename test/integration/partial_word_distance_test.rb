# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"
require "stringio"

class PartialWordDistanceTest < TinkickIntegrationTest
  MODES = [:word_start, :word_middle, :word_end].freeze

  class UseWhitespaceAnalysis < ActiveRecord::Migration[8.0]
    def up
      remove_index :tinkick_test_products, :name, using: :tin
      execute <<~SQL
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (tokenizer = whitespace, case_folding = preserve, accent_folding = preserve)
      SQL
    end

    def down
      remove_index :tinkick_test_products, :name, using: :tin
      add_index :tinkick_test_products, :name, using: :tin
    end
  end

  def test_each_mode_matches_two_edits_within_its_token_anchor
    names = { word_start: "abcdefghijzzzzz", word_middle: "zzzzzabcdefghijzzzzz", word_end: "zzzzzabcdefghij" }
    names.each do |mode, name|
      tinkick_test_products(:red_apple).update!(name: name)

      assert_equal([name], search("abdcfeghij", match: mode).map(&:name))
      assert_empty(search("abdcfeghij", match: mode, transpositions: false))
      assert_empty(search("abdcfeghij", match: mode, prefix_length: 3))
      assert_equal([name], search("abcdefghij", match: mode, prefix_length: 99).map(&:name))
    end
  end

  def test_gram_lengths_are_bounded_to_fifty_unicode_characters
    value = "𐐨" * 60
    tinkick_test_products(:red_apple).update!(name: value)
    MODES.each do |mode|
      assert_equal([value], search("𐐨" * 50, match: mode, prefix_length: 99).map(&:name))
      assert_equal([value], search("𐐨" * 51, match: mode).map(&:name))
      assert_equal([value], search("𐐨" * 52, match: mode).map(&:name))
      assert_empty(search("𐐨" * 53, match: mode))
      assert_empty(search("𐐨" * 52, match: mode, prefix_length: 51))
    end
  end

  def test_impossible_words_follow_and_or_semantics
    MODES.each do |mode|
      assert_empty(search("#{"a" * 53} pear", match: mode))
      expected = search("pear", match: mode).map(&:id).sort
      assert_equal(expected, search("#{"a" * 53} pear", match: mode, operator: "or").map(&:id).sort)
    end
  end

  def test_short_fuzzy_candidates_remain_eligible
    tinkick_test_products(:red_apple).update!(name: "zz")
    MODES.each do |mode|
      assert_includes(search("a", match: mode).map(&:name), "zz")
    end
    tinkick_test_products(:red_apple).update!(name: "ab")
    MODES.each do |mode|
      assert_includes(search("abcd", match: mode).map(&:name), "ab")
    end
  end

  def test_matching_never_joins_separate_tokens
    tinkick_test_products(:red_apple).update!(name: "abcd efgh")
    MODES.each do |mode|
      assert_empty(search("abcdefgh", match: mode))
    end
  end

  def test_normalization_and_keycaps_preserve_literal_dictionary_tokens
    tinkick_test_products(:red_apple).update!(name: "Jalapeño")
    MODES.each do |mode|
      assert_equal(["Jalapeño"], search("ajlapneo", match: mode).map(&:name))
    end
    tinkick_test_products(:red_apple).update!(name: "#️⃣")
    MODES.each do |mode|
      assert_equal(["#️⃣"], search("#️⃣", match: mode, prefix_length: 99).map(&:name))
      assert_empty(search("*️⃣", match: mode, prefix_length: 99))
      assert_empty(search('") OR [pear] ^10000', match: mode))
    end
  end

  def test_custom_analysis_preserves_case_accents_and_punctuation
    migration = UseWhitespaceAnalysis.new
    migration.migrate(:up)
    begin
      tinkick_test_products(:red_apple).update!(name: "AND wi-fi Jalapeño")
      MODES.each do |mode|
        assert_equal(["AND wi-fi Jalapeño"], search("AND", match: mode, prefix_length: 3).map(&:name))
        assert_empty(search("and", match: mode, prefix_length: 3))
        assert_equal(["AND wi-fi Jalapeño"], search("wi-fi", match: mode, prefix_length: 5).map(&:name))
        assert_empty(search("jalapeno", match: mode, prefix_length: 8))
      end
    ensure
      migration.migrate(:down)
    end
  end

  def test_json_scalar_guards_filters_and_counts_remain_consistent
    apple = tinkick_test_products(:red_apple)
    apple.update!(metadata: { title: "zzzzzabcdefghzzzzz" })
    tinkick_test_products(:green_pear).update!(metadata: { title: { text: "zzzzzabcdefghzzzzz" } })
    result = search("badcefgh", match: :word_middle, fields: ["metadata.title"], where: { id: apple.id })

    assert_equal([apple.id], result.map(&:id))
    assert_equal(1, result.total_count)
    assert_equal([apple.id], search("badcefgh", match: :word_middle, fields: ["metadata.title"]).map(&:id))
  end

  def test_warned_sql_refinement_keeps_native_index_candidates
    previous_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    tinkick_test_products(:red_apple).update!(name: "zzzzzabcdefghzzzzz")
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal(["zzzzzabcdefghzzzzz"], search("badcefgh", match: :word_middle).map(&:name))
    end
    assert_includes(output.string, "gram")
    assert_includes(output.string, "top-k")
    statement = statements.find { |entry| entry[:sql].include?(" AS _tinkick_score") }
    plan = SearchProduct.connection.select_value(
      "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick Partial Distance Explain", statement.fetch(:binds),
    )

    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, "index_tinkick_test_products_on_name")
    assert_includes(plan, '"Function Name": "tokenize"')
    assert_includes(plan, '"Function Name": "generate_series"')
    refute_includes(plan, '"Top K"')
  ensure
    SearchProduct.logger = previous_logger
  end

  private

  def search(term, match:, transpositions: true, prefix_length: 0, **options)
    @model ||= Class.new(SearchProduct) { tinkick searchable: [:name] }
    @model.search(term, match: match,
      misspellings: { edit_distance: 2, transpositions: transpositions, prefix_length: prefix_length }, **options)
  end
end
