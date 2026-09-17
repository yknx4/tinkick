# frozen_string_literal: true

require_relative "../integration_helper"

class GeneratedColumnsTest < TinkickIntegrationTest
  test "searches a stored generated field combining model columns" do
    search = query("apple orchard")

    assert_equal ["Red Apple"], search.records.map(&:name)
    assert_equal 1, search.total_count
    assert_equal "Red Apple Fresh orchard fruit", search.records.first.display_name

    column = SearchProduct.columns_hash.fetch("display_name")
    assert_equal :text, column.type
    assert column.virtual?
    generated = SearchProduct.connection.select_value(<<~SQL)
      SELECT attgenerated FROM pg_attribute
      WHERE attrelid = 'tinkick_test_products'::regclass AND attname = 'display_name'
    SQL
    assert_equal "s", generated

    separate_fields = Tinkick::Query.new(SearchProduct, "apple orchard", fields: [:name, :description])
    assert_empty separate_fields.records
  end

  test "model updates immediately update the generated field and its TIN results" do
    product = tinkick_test_products(:red_apple)
    assert_equal [product.id], query("apple orchard").records.map(&:id)

    product.update!(name: "Yellow Banana", description: "Tropical snack")

    assert_empty query("apple orchard").records
    assert_equal [product.id], query("banana tropical").records.map(&:id)
    assert_equal "Yellow Banana Tropical snack", product.reload.display_name

    SearchProduct.where(id: product.id).update_all(name: "Golden Mango")

    assert_empty query("banana tropical").records
    assert_equal [product.id], query("mango tropical").records.map(&:id)
    assert_equal "Golden Mango Tropical snack", product.reload.display_name
  end

  test "new records with null descriptions remain searchable" do
    product = SearchProduct.create!(name: "Persimmon", description: nil)

    assert_equal [product.id], query("persimmon").records.map(&:id)
    assert_equal 1, query("persimmon").total_count
    assert_equal "Persimmon ", product.reload.display_name
  end

  private

  def query(term)
    Tinkick::Query.new(SearchProduct, term, fields: [:display_name])
  end
end
