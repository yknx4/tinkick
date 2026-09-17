# frozen_string_literal: true

require_relative "../integration_helper"

class RecencyJsonFieldsTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  def test_json_date_paths_explain_the_typed_column_requirement_when_scoring
    product = tinkick_test_products(:red_apple)
    product.update!(metadata: { published_at: "2026-09-17T12:00:00Z" })
    page = search(boost_by_recency: { "metadata.published_at" => { scale: "7d" } })

    assert_equal 1, page.total_count
    error = assert_raises(Tinkick::InvalidQueryError) { page.to_a }
    assert_includes error.message, "metadata.published_at"
    assert_includes error.message, "JSONB"
    assert_includes error.message, "typed date or numeric column"
    assert_includes error.message, "Rails migration"
    refute_includes error.message, "not supported by TIN"
    assert_equal "2026-09-17T12:00:00Z", product.reload.metadata.fetch("published_at")
  end

  def test_json_numeric_values_require_typed_columns_without_changing_numeric_column_search
    product = tinkick_test_products(:red_apple)
    product.update!(metadata: { offers: { distance: 10 } })

    error = assert_raises(Tinkick::InvalidQueryError) do
      search(boost_by_recency: { "metadata.offers.distance" => { origin: 10, scale: 5 } }).to_a
    end
    assert_includes error.message, "metadata.offers.distance"
    assert_includes error.message, "stored or generated"

    baseline = search.with_score.first.last
    page = search(boost_by_recency: { id: { origin: product.id, scale: 5 } })
    assert_equal [product.id], page.map(&:id)
    assert_in_delta baseline, page.with_score.first.last, 0.000001
  end

  def test_missing_roots_and_non_json_roots_keep_the_missing_field_error
    ["missing.published_at", "name.published_at"].each do |field|
      error = assert_raises(Tinkick::MissingFieldError) do
        search(boost_by_recency: { field => { scale: "7d" } }).to_a
      end
      assert_includes error.message, field
    end
  end

  private

  def search(**options)
    Product.search("apple", fields: [:name], misspellings: false, **options)
  end
end
