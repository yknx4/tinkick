# frozen_string_literal: true

require_relative "../integration_helper"

class CustomPhraseHighlightTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  class RebuildNameIndex < ActiveRecord::Migration[8.0]
    attr_accessor :options

    def up
      remove_index(:tinkick_test_products, :name, using: :tin)
      settings = options.map { |name, value| "#{name} = #{connection.quote(value)}" }.join(", ")
      execute(<<~SQL)
        CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name)
        WITH (#{settings})
      SQL
    end

    def down
      remove_index(:tinkick_test_products, :name, using: :tin)
      add_index(:tinkick_test_products, :name, using: :tin)
    end
  end

  setup do
    @first, @second = [tinkick_test_products(:red_apple), tinkick_test_products(:green_pear)].sort_by(&:id)
  end

  teardown do
    @migration&.migrate(:down)
    SearchProduct.reset_column_information
  end

  def test_phrase_highlights_respect_each_fields_case_and_accent_analysis
    rebuild_index(tokenizer: "whitespace", case_folding: "preserve", accent_folding: "preserve")
    @first.update!(name: "Fëanor arrives fëanor arrives Fëanor waits arrives", description: "Unrelated maps")
    @second.update!(name: "fëanor arrives", description: "Fëanor arrives")

    search = Product.search("Fëanor arrives", fields: [:name, :description], match: :phrase, highlight: true)
    values = search.with_highlights.to_h { |record, highlights| [record.id, highlights] }

    assert_equal({ name: "<em>Fëanor arrives</em> fëanor arrives Fëanor waits arrives" }, values.fetch(@first.id))
    assert_equal({ description: "<em>Fëanor arrives</em>" }, values.fetch(@second.id))
  end

  def test_split_phrase_highlights_only_its_complete_stored_fragment_witness
    rebuild_index(tokenizer: "whitespace", max_token_bytes: 4)
    @first.update!(name: "abcdefghij")
    @second.update!(name: "abcdefghxxij")

    search = phrase("efgh ij")

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "abcd<em>efghij</em>" }], search.highlights
  end

  def test_truncated_phrase_spans_include_internal_source_context
    rebuild_index(tokenizer: "whitespace", max_token_bytes: 4, long_tokens: "truncate")
    @first.update!(name: "abcdefghij bb")
    @second.update!(name: "abcdefghij cc bb")

    search = phrase("abcd bb")

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "<em>abcdefghij bb</em>" }], search.highlights
    assert_equal [{ name: "<em>abcd</em>efghij bb" }], phrase("abcd", where: { id: @first.id }).highlights
  end

  def test_preserved_internal_gaps_match_positions_without_highlighting_query_edge_gaps
    rebuild_index(tokenizer: "whitespace", max_token_bytes: 4, long_tokens: "discard")
    @first.update!(name: "prefix aa cc bb suffix")
    @second.update!(name: "aa bb")

    search = phrase("toolong aa toolong bb toolong")

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "prefix <em>aa cc bb</em> suffix" }], search.highlights
  end

  def test_collapsed_discarded_tokens_do_not_hide_retained_intervening_words
    rebuild_index(tokenizer: "whitespace", max_token_bytes: 4, long_tokens: "discard", position_gaps: "collapse")
    @first.update!(name: "aa toolong bb")
    @second.update!(name: "aa cc bb")

    search = phrase("aa toolong bb")

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "<em>aa toolong bb</em>" }], search.highlights
  end

  def test_unicode_phrase_uses_hidden_cached_page_text_and_shared_html_renderer
    rebuild_index(case_folding: "preserve", accent_folding: "preserve")
    @first.update!(name: "<b> Éowyn $ arrives </b>")
    @second.update!(name: "Éowyn arrives")
    search = phrase("Éowyn arrives", highlight: { encoder: "html" },
      select: [], load: false, countless: true, limit: 1, order: :id)

    statements = capture_queries do
      assert_equal "&lt;b&gt; <em>Éowyn $ arrives</em> &lt;&#x2F;b&gt;", search.to_a.first.highlighted_name
      assert_nil search.to_a.first["name"]
      refute search.hits.first.key?("_source")
      assert search.has_next_page?
    end
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_equal 1, statements.count { |sql| sql.include?(" AS _tinkick_score") }

    @first.update!(name: "Updated after the result page was loaded")
    cached_queries = capture_queries do
      assert_equal [{ name: "&lt;b&gt; <em>Éowyn $ arrives</em> &lt;&#x2F;b&gt;" }], search.highlights
      assert_same search.hits, search.response.fetch("hits").fetch("hits")
    end
    assert_empty cached_queries
  end

  def test_phrase_and_word_modes_merge_overlapping_spans_without_nested_markers
    rebuild_index(tokenizer: "whitespace")
    @first.update!(name: "aa bb aa xx bb")
    @second.update!(name: "aa xx bb")
    search = Product.search("aa bb", fields: [{ name: :phrase }, { name: :word }],
      misspellings: false, highlight: true, order: :id)

    assert_equal [@first.id, @second.id], search.map(&:id)
    assert_equal [{ name: "<em>aa bb</em> <em>aa</em> xx <em>bb</em>" },
                  { name: "<em>aa</em> xx <em>bb</em>" }], search.highlights
  end

  private

  def phrase(term, **options)
    Product.search(term, fields: [:name], match: :phrase, highlight: true, **options)
  end

  def rebuild_index(**options)
    @migration = RebuildNameIndex.new
    @migration.options = options
    @migration.migrate(:up)
    SearchProduct.reset_column_information
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
