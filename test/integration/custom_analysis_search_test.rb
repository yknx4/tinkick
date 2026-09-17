# frozen_string_literal: true

require_relative "../integration_helper"
require "stringio"

class CustomAnalysisSearchTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
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

  class PreserveLongNameTokens < ActiveRecord::Migration[8.0]
    def up
      remove_index(:tinkick_test_products, :name, using: :tin)
      execute(<<~SQL)
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (tokenizer = whitespace, case_folding = preserve, accent_folding = preserve, max_token_bytes = 1024)
      SQL
    end
  end

  class FoldNameCase < ActiveRecord::Migration[8.0]
    def up
      remove_index(:tinkick_test_products, :name, using: :tin)
      execute(<<~SQL)
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (tokenizer = whitespace, case_folding = fold, accent_folding = preserve)
      SQL
    end
  end

  setup do
    @migration = PreserveNameAnalysis.new
    @migration.migrate(:up)
    @preserved = true
    SearchProduct.reset_column_information
    @first = tinkick_test_products(:red_apple)
    @second = tinkick_test_products(:green_pear)
    @first.update!(description: "Unrelated orchard")
    @second.update!(description: "Distant coastline")
  end

  teardown do
    @migration.migrate(:down) if @preserved
    SearchProduct.reset_column_information
  end

  def test_literal_words_use_the_index_case_accents_and_word_boundaries
    [["FooBar", "foobar"], ["Jalapeño", "jalapeno"], ["wi-fi", "wi fi"], ["AND", "and"]].each do |term, control|
      @first.update!(name: term)
      @second.update!(name: control)

      assert_equal([@first.id], search(term).map(&:id), term)
      assert_equal([@second.id], search(control).map(&:id), control)
      assert_equal(1, search(term).total_count)
    end
  end

  def test_phrases_keep_indexed_whitespace_tokens_and_literal_punctuation
    @first.update!(name: 'AND wi-fi tag) "Quoted"')
    @second.update!(name: 'and wi fi tag "Quoted"')

    assert_equal([@first.id], search("AND wi-fi", match: :phrase).map(&:id))
    assert_equal([@first.id], search('tag) "Quoted"', match: :phrase).map(&:id))
    assert_empty(search("AND wi fi", match: :phrase))
    assert_equal([@second.id], search("and wi fi", match: :phrase).map(&:id))
  end

  def test_partial_patterns_preserve_case_and_escape_tinql_and_regex_tokens
    { word_start: ["", "tail"], word_middle: ["lead", "tail"], word_end: ["lead", ""] }.each do |mode, (leading, trailing)|
      ["FooBar", "AND", "a(b)", "a.*", "foo\\bar", 'a"b'].each do |term|
        @first.update!(name: "#{leading}#{term}#{trailing}")
        @second.update!(name: "#{leading}unrelated#{trailing}")

        assert_equal([@first.id], search(term, match: mode).map(&:id), "#{mode}: #{term}")
      end
      @first.update!(name: "#{leading}FooBar#{trailing}")
      @second.update!(name: "#{leading}foobar#{trailing}")
      assert_equal([@second.id], search("foobar", match: mode).map(&:id))
    end
  end

  def test_each_selected_field_uses_its_own_index_analysis
    @first.update!(name: "FooBar")
    @second.update!(name: "Unrelated", description: "FOOBAR")

    assert_equal([@first.id, @second.id].sort, search("FooBar", fields: [:name, :description]).map(&:id).sort)
    assert_equal([@second.id], search("foobar", fields: [:name, :description]).map(&:id))
    assert_equal([@first.id], search("FooBar", exclude: "foobar").map(&:id))
    assert_empty(search("FooBar", exclude: "FooBar"))
  end

  def test_warm_schema_reuses_analysis_without_another_index_catalog_read
    @first.update!(name: "FooBar")
    @second.update!(name: "foobar")
    assert_equal([@first.id], search("FooBar").map(&:id))

    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal([@first.id], search("FooBar").map(&:id))
      assert_empty(search("FooBar", exclude: "FooBar"))
    end
    refute(statements.any? { |sql| sql.include?("pg_catalog.pg_index") })
  end

  def test_reset_column_information_refreshes_analysis_after_index_rebuild
    @first.update!(name: "FooBar")
    @second.update!(name: "foobar")
    assert_equal([@first.id], search("Foo", match: :word_start).map(&:id))

    @migration.migrate(:down)
    @preserved = false
    SearchProduct.reset_column_information

    assert_equal([@first.id, @second.id].sort, search("Foo", match: :word_start).map(&:id).sort)
    assert_equal([@first.id, @second.id].sort, search("FooBar").map(&:id).sort)
  end

  def test_fuzzy_whitespace_tokens_escape_native_query_syntax_and_preserve_prefixes
    ['a(b)', 'a[b]', 'a"b', "a\\b", "a~b", "a^b", "a*b", "a?b", "AND"].each do |term|
      @first.update!(name: term)
      @second.update!(name: "Z#{term[1..]}")

      assert_equal([@first.id, @second.id].sort, search(term, misspellings: true).map(&:id).sort, term)
      assert_equal([@first.id], search(term, misspellings: { prefix_length: 1 }).map(&:id), term)
      assert_equal([@first.id, @second.id].sort,
        search(term, misspellings: { transpositions: false }).map(&:id).sort, term)
    end
  end

  def test_fuzzy_preserved_tokens_support_transpositions_and_long_whole_words
    @first.update!(name: "a(b)")
    @second.update!(name: "Unrelated")
    assert_equal([@first.id], search("ab()", misspellings: true).map(&:id))
    assert_empty(search("ab()", misspellings: { transpositions: false }))

    term = "A" * 90
    @first.update!(name: term)
    @second.update!(name: "A" * 45 + "B" + "A" * 44)
    assert_equal([@first.id, @second.id].sort, search(term, misspellings: true).map(&:id).sort)
    assert_empty(search(term.downcase, misspellings: true))
  end

  def test_fuzzy_partials_keep_preserved_index_tokens_and_per_field_controls
    { word_start: "ANXtail", word_middle: "leadANXtail", word_end: "leadANX" }.each do |mode, name|
      @first.update!(name: name, description: "Unrelated")
      @second.update!(name: "and", description: "AND")
      fields = [{ name: mode }, :description]
      options = { fields: fields, misspellings: { fields: [:name], prefix_length: 2 } }

      assert_equal([@first.id, @second.id].sort, search("AND", **options).map(&:id).sort)
      assert_equal([@second.id], search("AND", **options.merge(misspellings: { fields: [], prefix_length: 2 })).map(&:id))
      assert_equal([@second.id], search("AND", **options.merge(misspellings: { fields: [:name], prefix_length: 3 })).map(&:id))
    end
  end

  def test_fifty_character_fuzzy_literals_match_insertions_and_keep_native_top_k
    term = "A" * 49 + ")"
    @first.update!(name: term)
    @second.update!(name: "A" * 49 + "X)")
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal([@first.id, @second.id].sort, search(term, misspellings: true, limit: 10).map(&:id).sort)
    end
    statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_score") }
    plan = Product.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick Preserved Fuzzy Explain", statement.fetch(:binds))
    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, '"Top K": "10"')
    refute_includes(plan, "osa_distance")
    assert_equal([@first.id], search(term, misspellings: { prefix_length: 50 }).map(&:id))
  end

  def test_long_fuzzy_delimiters_preserve_prefixes_and_exact_exclusions
    term = "A" * 60 + "(b)"
    @first.update!(name: term)
    @second.update!(name: "Z#{term[1..]}")

    assert_equal([@first.id, @second.id].sort, search(term, misspellings: true).map(&:id).sort)
    assert_equal([@first.id], search(term, misspellings: { prefix_length: 1 }).map(&:id))
    assert_equal([@second.id], search(term, misspellings: true, exclude: term).map(&:id))
    assert_equal(1, search(term, misspellings: true, exclude: term).total_count)
    assert_empty(search(term.downcase, misspellings: true))
  end

  def test_two_edit_literal_delimiters_can_disable_transpositions
    @first.update!(name: "ab()")
    @second.update!(name: "Wrong")
    options = { edit_distance: 2, transpositions: false }

    assert_equal([@first.id], search("a(b)", misspellings: options).map(&:id))
    assert_empty(search("a(b)", misspellings: options.merge(edit_distance: 1)))
    assert_empty(search("a(b)", misspellings: options.merge(prefix_length: 2)))
    assert_empty(search("a(b)", misspellings: options, exclude: "ab()"))

    @first.update!(name: "#")
    @second.update!(name: "$")
    assert_equal([@first.id, @second.id].sort, search("#", misspellings: options).map(&:id).sort)
  end

  def test_refinement_uses_custom_long_token_limits_without_fuzzystrmatch_truncation
    PreserveLongNameTokens.new.migrate(:up)
    SearchProduct.reset_column_information
    term = "A" * 300 + "()"
    @first.update!(name: term)
    @second.update!(name: "A" * 300 + ")(")

    assert_equal([@first.id, @second.id].sort, search(term, misspellings: true).map(&:id).sort)
    assert_equal([@first.id], search(term, misspellings: { transpositions: false }).map(&:id))
    assert_equal([@first.id, @second.id].sort,
      search(term, misspellings: { edit_distance: 2, transpositions: false }).map(&:id).sort)
    assert_equal([@first.id], search(term, misspellings: { prefix_length: 301 }).map(&:id))
  end

  def test_refinement_threshold_uses_analyzed_codepoints_after_case_folding
    FoldNameCase.new.migrate(:up)
    SearchProduct.reset_column_information
    term = "İ" * 30 + ")"
    @first.update!(name: term)
    @second.update!(name: "Unrelated")

    assert_equal([@first.id], search(term, misspellings: true).map(&:id))
  end

  def test_refined_literal_tokens_warn_and_use_tin_candidates_in_the_real_plan
    term = "A" * 60 + ")"
    @first.update!(name: term)
    @second.update!(name: "Z" * 60 + ")")
    previous_logger = Product.logger
    messages = StringIO.new
    Product.logger = Logger.new(messages)
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal([@first.id], search(term, misspellings: true, limit: 10).map(&:id))
    end
    assert_includes(messages.string, "top-k")
    statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_score") }
    assert_includes(statement.fetch(:sql), "tinkick.edit_distance")
    plan = Product.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick Refined Literal Explain", statement.fetch(:binds))
    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, '"Function Name": "tokenize"')
  ensure
    Product.logger = previous_logger
  end

  private

  def search(term, **options)
    Product.search(term, fields: [:name], misspellings: false, **options)
  end
end
