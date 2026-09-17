# frozen_string_literal: true

require_relative "../integration_helper"

class CustomPolicyHighlightTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
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

  def test_split_index_highlights_only_the_matching_stored_fragment
    rebuild_index(max_token_bytes: 4, long_tokens: "split")
    @first.update!(name: "abcdefghij")
    @second.update!(name: "abcduvwxij")

    search = Product.search("efgh", misspellings: false, highlight: true)

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "abcd<em>efgh</em>ij" }], search.highlights
  end

  def test_truncate_index_excludes_raw_suffixes_and_marks_only_stored_prefixes
    rebuild_index(max_token_bytes: 4, long_tokens: "truncate")
    @first.update!(name: "abcdefghij abcd")
    @second.update!(name: "efgh")

    search = Product.search("abcd", misspellings: false, highlight: true)

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "<em>abcd</em>efghij <em>abcd</em>" }], search.highlights
    assert_equal [@second.id], Product.search("efgh", misspellings: false).map(&:id)
  end

  def test_discard_index_does_not_highlight_a_transient_prefix_of_a_removed_word
    rebuild_index(max_token_bytes: 4, long_tokens: "discard")
    @first.update!(name: "abcdLONG-abcd")
    @second.update!(name: "abcdLONG-only")

    search = Product.search("abcd", misspellings: false, highlight: true)

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "abcdLONG-<em>abcd</em>" }], search.highlights
  end

  def test_multibyte_fragments_preserve_index_case_and_accents
    rebuild_index(max_token_bytes: 4, case_folding: "preserve", accent_folding: "preserve")
    @first.update!(name: "ÉÉééX")
    @second.update!(name: "ÉÉeeX")

    search = Product.search("éé", misspellings: false, highlight: true)

    assert_equal [@first.id], search.map(&:id)
    assert_equal [{ name: "ÉÉ<em>éé</em>X" }], search.highlights
  end

  def test_retained_symbols_use_hidden_page_text_and_shared_html_encoding
    rebuild_index(graphemes: "retain")
    @first.update!(name: "<b>©</b> $")
    @second.update!(name: "© archive")
    search = Product.search("©", misspellings: false, highlight: { encoder: "html" },
      select: [], load: false, countless: true, limit: 1, order: :id)

    statements = capture_queries do
      assert_equal "&lt;b&gt;<em>©</em>&lt;&#x2F;b&gt; $", search.to_a.first.highlighted_name
      assert_nil search.to_a.first["name"]
      refute search.hits.first.key?("_source")
      assert search.has_next_page?
    end

    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_equal 1, statements.count { |sql| sql.include?(" AS _tinkick_score") }
    assert_empty capture_queries { search.highlights }
  end

  private

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
