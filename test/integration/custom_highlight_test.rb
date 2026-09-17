# frozen_string_literal: true

require_relative "../integration_helper"

class CustomHighlightTest < TinkickIntegrationTest
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

  class PreserveUnicodeNameAnalysis < ActiveRecord::Migration[8.0]
    def up
      remove_index(:tinkick_test_products, :name, using: :tin)
      execute(<<~SQL)
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (case_folding = preserve, accent_folding = preserve)
      SQL
    end
  end

  setup do
    @migration = PreserveNameAnalysis.new
    @migration.migrate(:up)
    SearchProduct.reset_column_information
    @first = tinkick_test_products(:red_apple)
    @second = tinkick_test_products(:green_pear)
    @first.update!(name: "Fëanor fëanor Feanor Fëanor", description: "An unrelated pottery lesson")
    @second.update!(name: "fëanor", description: "Fëanor archive")
  end

  teardown do
    @migration.migrate(:down)
    SearchProduct.reset_column_information
  end

  def test_each_field_highlights_with_its_own_case_accent_and_token_policy
    search = Product.search("Fëanor", fields: ["name^2", :description], misspellings: false, highlight: true)
    values = search.with_highlights.to_h { |record, highlights| [record.id, highlights] }

    assert_equal({ name: "<em>Fëanor</em> fëanor Feanor <em>Fëanor</em>" }, values.fetch(@first.id))
    assert_equal({ description: "<em>Fëanor</em> archive" }, values.fetch(@second.id))
    assert_equal 2, search.hits.length
    assert_same search.hits, search.response.fetch("hits").fetch("hits")
    assert_empty capture_queries {
                   search.highlights
                   search.with_highlights.to_a }
  end

  def test_whitespace_punctuation_is_part_of_the_highlighted_token
    @first.update!(name: "Beyond wi-fi AND Rivendell")
    @second.update!(name: "wi fi and Rivendell")

    search = Product.search("wi-fi", fields: [:name], misspellings: false, highlight: true)
    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "Beyond <em>wi-fi</em> AND Rivendell" }], search.highlights
  end

  def test_partial_fuzzy_highlighting_keeps_case_and_prefix_restrictions
    @first.update!(name: "RivendelArchive")
    @second.update!(name: "rivendellarchive")

    search = Product.search("Rivendell", fields: [:name], match: :word_start,
      misspellings: { prefix_length: 1 }, highlight: true)
    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "<em>RivendelArchive</em>" }], search.highlights
  end

  def test_unicode_spans_preserve_html_and_hidden_raw_projection_without_counts
    PreserveUnicodeNameAnalysis.new.migrate(:up)
    SearchProduct.reset_column_information
    @first.update!(name: "<b>Éowyn</b> eowyn EOWYN")
    @second.update!(name: "Éowyn by the river")
    search = Product.search("Éowyn", fields: [:name], misspellings: false,
      highlight: { encoder: "html" }, select: [], load: false, countless: true, limit: 1, order: :name)

    statements = capture_queries do
      assert_equal "&lt;b&gt;<em>Éowyn</em>&lt;&#x2F;b&gt; eowyn EOWYN", search.to_a.first.highlighted_name
      assert_nil search.to_a.first["name"]
      refute search.hits.first.key?("_source")
      assert search.has_next_page?
    end
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_equal 1, statements.count { |sql| sql.include?(" AS _tinkick_score") }
  end

  def test_exact_first_retry_does_not_highlight_unneeded_fuzzy_expansions
    @first.update!(name: "Fëanor Féanor")
    search = Product.search("Fëanor", fields: [:name], misspellings: { below: 1 }, highlight: true)

    assert_equal [{ name: "<em>Fëanor</em> Féanor" }], search.highlights
    refute search.misspellings?
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
