# frozen_string_literal: true

require_relative "../../lib/tinkick/word_match"
require_relative "../integration_helper"
require "stringio"

class WordMatchTest < TinkickIntegrationTest
  class UseWhitespaceAnalysis < ActiveRecord::Migration[8.0]
    def up
      remove_index :tinkick_test_products, :name, using: :tin
      execute <<~SQL
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (tokenizer = whitespace, case_folding = preserve, accent_folding = preserve)
      SQL
      SearchProduct.reset_column_information
    end

    def down
      remove_index :tinkick_test_products, :name, using: :tin
      add_index :tinkick_test_products, :name, using: :tin
      SearchProduct.reset_column_information
    end
  end

  class AddConflictingAnalysis < ActiveRecord::Migration[8.0]
    def up
      execute <<~SQL
        CREATE INDEX tinkick_word_match_conflicting_tin ON tinkick_test_products USING tin (name)
        WITH (case_folding = preserve)
      SQL
      SearchProduct.reset_column_information
    end

    def down
      remove_index :tinkick_test_products, name: :tinkick_word_match_conflicting_tin
      SearchProduct.reset_column_information
    end
  end

  def test_two_disjoint_transpositions_use_native_candidates_and_exact_refinement
    assert_equal(["Red Apple"], search("papel").map(&:name))
    assert_equal(["Red Apple"], search("apple").map(&:name))
    refute_includes(search("apple").map(&:name), "Green Pear")
  end

  def test_restricted_transposition_distance_rejects_reusing_an_edited_character
    tinkick_test_products(:red_apple).update!(name: "abc")
    tinkick_test_products(:green_pear).update!(name: "ca")

    assert_equal(["ca"], search("ca").map(&:name))
  end

  def test_prefix_length_is_fixed_before_edit_distance
    assert_empty(search("papel", prefix_length: 1))
    assert_equal(["Red Apple"], search("appel", prefix_length: 1).map(&:name))
    assert_equal(["Red Apple"], search("apple", prefix_length: 99).map(&:name))
  end

  def test_each_query_word_uses_the_requested_and_or_semantics
    assert_equal(["Red Apple"], search("rde papel").map(&:name))
    assert_empty(search("papel nopossiblematch"))
    assert_equal(["Red Apple"], search("papel nopossiblematch", operator: "or").map(&:name))
  end

  def test_native_normalization_preserves_unicode_codepoints
    tinkick_test_products(:red_apple).update!(name: "Jalapeño")
    assert_equal(["Jalapeño"], search("ajlapneo").map(&:name))

    tinkick_test_products(:red_apple).update!(name: "𐐀𐐁𐐂𐐃")
    assert_equal(["𐐀𐐁𐐂𐐃"], search("𐐁𐐀𐐃𐐂").map(&:name))
  end

  def test_keycaps_are_literal_tokens_and_query_syntax_is_not_executable
    tinkick_test_products(:red_apple).update!(name: "*️⃣")
    assert_equal(["*️⃣"], search("#️⃣").map(&:name))
    assert_empty(search('" AND NOT [pear] ^10000'))
    assert_empty(search("\\"))
  end

  def test_json_scalar_expression_uses_its_own_index
    tinkick_test_products(:red_apple).update!(metadata: { title: "Apple" })
    assert_equal(["Red Apple"], search("papel", field: "metadata.title").map(&:name))
  end

  def test_index_analysis_is_applied_to_query_and_document_tokens
    migration = UseWhitespaceAnalysis.new
    migration.migrate(:up)
    begin
      tinkick_test_products(:red_apple).update!(name: "AND wi-fi Jalapeño")
      assert_equal(["AND wi-fi Jalapeño"], search("AND", prefix_length: 3).map(&:name))
      assert_empty(search("and", prefix_length: 3))
      assert_equal(["AND wi-fi Jalapeño"], search("wi-fi", prefix_length: 5).map(&:name))
      assert_empty(search("jalapeno", prefix_length: 8))
    ensure
      migration.migrate(:down)
    end
  end

  def test_conflicting_index_analysis_fails_instead_of_changing_eligibility
    migration = AddConflictingAnalysis.new
    migration.migrate(:up)
    begin
      error = assert_raises(Tinkick::Error) { search("papel") }
      assert_includes(error.message, "conflicting tokenization")
    ensure
      migration.migrate(:down)
    end
  end

  def test_slow_path_warns_and_uses_indexed_candidates_in_the_real_plan
    output = StringIO.new
    previous_logger = SearchProduct.logger
    SearchProduct.logger = Logger.new(output)
    relation = search("papel").select("tinkick_test_products.*", Arel.sql("tin.score(tinkick_test_products.ctid) AS _tinkick_score"))
      .reorder(Arel.sql("_tinkick_score DESC")).limit(10)
    assert_equal(["Red Apple"], relation.map(&:name))
    assert_includes(output.string, "top-k")
    assert_includes(output.string, "token")
    plan = SearchProduct.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{relation.to_sql}")
    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, "index_tinkick_test_products_on_name")
    assert_includes(plan, '"Function Name": "tokenize"')
  ensure
    SearchProduct.logger = previous_logger
  end

  private

  def search(term, field: "name", prefix_length: 0, operator: "and")
    sql, binds = Tinkick::WordMatch.new(SearchProduct).predicate(
      field, term, operator: operator, misspellings: { edit_distance: 2, prefix_length: prefix_length },
    )
    SearchProduct.where(Arel.sql(sql, *binds)).order(:name)
  end
end
