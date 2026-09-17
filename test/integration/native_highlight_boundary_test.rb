# frozen_string_literal: true

require_relative "../integration_helper"

class NativeHighlightBoundaryTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  class RebuildNameIndex < ActiveRecord::Migration[8.0]
    attr_accessor :options

    def up
      remove_index(:tinkick_test_products, :name, using: :tin)
      settings = options.map { |name, value| "#{name} = #{connection.quote(value)}" }.join(", ")
      execute("CREATE INDEX index_tinkick_test_products_on_name ON tinkick_test_products USING tin (name) WITH (#{settings})")
    end

    def down
      remove_index(:tinkick_test_products, :name, using: :tin)
      add_index(:tinkick_test_products, :name, using: :tin)
    end
  end

  setup do
    @product = tinkick_test_products(:red_apple)
    @product.update!(name: "Fëanor arrives", description: "Fëanor arrives in the archive")
  end

  teardown do
    @migration&.migrate(:down)
    SearchProduct.reset_column_information
  end

  def test_custom_case_and_accent_highlighting_reports_native_boundary
    rebuild_index(case_folding: "preserve", accent_folding: "preserve")

    assert_native_boundary(Product.search("Fëanor", fields: [:name], misspellings: false, highlight: true))
  end

  def test_whitespace_phrase_highlighting_does_not_reconstruct_positions
    rebuild_index(tokenizer: "whitespace")

    assert_native_boundary(Product.search("Fëanor arrives", fields: [:name], match: :phrase, misspellings: false, highlight: true))
  end

  def test_changed_token_policy_highlighting_does_not_retokenize_prefixes
    rebuild_index(long_tokens: "truncate", max_token_bytes: 4)
    @product.update!(name: "abcdefghij")

    assert_native_boundary(Product.search("abcd", fields: [:name], misspellings: false, highlight: true))
  end

  def test_default_analysis_field_can_be_highlighted_beside_a_custom_field
    rebuild_index(tokenizer: "whitespace", case_folding: "preserve")
    search = Product.search("Fëanor", fields: [:name, :description], where: { id: @product.id },
      misspellings: false, highlight: { fields: [:description] })

    assert_equal [{ description: "<em>Fëanor</em> arrives in the archive" }], search.highlights
  end

  def test_sql_exact_highlights_the_whole_field_without_token_offsets
    rebuild_index(tokenizer: "whitespace", case_folding: "preserve")
    search = Product.search("Fëanor arrives", fields: [:name], match: :exact,
      misspellings: false, highlight: true)

    assert_equal [{ name: "<em>Fëanor arrives</em>" }], search.highlights
  end

  private

  def rebuild_index(**options)
    @migration = RebuildNameIndex.new
    @migration.options = options
    @migration.migrate(:up)
    SearchProduct.reset_column_information
  end

  def assert_native_boundary(search)
    error = assert_raises(Tinkick::NotImplementedError) { search.highlights }

    assert_match(/native TIN.*highlight/i, error.message)
    assert_match(/name/, error.message)
  end
end
