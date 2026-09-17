# frozen_string_literal: true

require_relative "../integration_helper"

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

  private

  def search(term, **options)
    Product.search(term, fields: [:name], misspellings: false, **options)
  end
end
