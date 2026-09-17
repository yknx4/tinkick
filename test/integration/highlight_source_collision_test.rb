# frozen_string_literal: true

require_relative "../integration_helper"

class HighlightSourceCollisionTest < Minitest::Test
  class Product < ActiveRecord::Base
    self.table_name = "tinkick_highlight_source_products"
    tinkick searchable: [:name]
  end

  class CreateProducts < ActiveRecord::Migration[8.0]
    def change
      create_table :tinkick_highlight_source_products do |table|
        table.text :name
        table.jsonb :highlighted_name
      end
      add_index :tinkick_highlight_source_products, :name, using: :tin
    end
  end

  def test_truthy_source_values_are_preserved_with_and_without_native_spans
    with_highlighted_column do
      ["Editorial title", "", true, 0].each do |value|
        Product.where(id: @product_id).update_all(highlighted_name: value)
        ["apple", "*"].each do |term|
          search = search(term)
          assert_equal value, search.to_a.first.highlighted_name
          assert_equal value, search.hits.first.fetch("_source").fetch("highlighted_name")
        end
      end
    end
    refute Product.table_exists?
  end

  def test_false_and_nil_source_values_use_the_highlight_or_original_field
    with_highlighted_column do
      [false, nil].each do |value|
        Product.where(id: @product_id).update_all(highlighted_name: value)
        assert_equal "Red <em>Apple</em>", search("apple").to_a.first.highlighted_name
        assert_equal "Red Apple", search("*").to_a.first.highlighted_name
      end
    end
    refute Product.table_exists?
  end

  private

  def search(term)
    Product.search(term, where: { id: @product_id }, highlight: true, load: false, misspellings: false)
  end

  def with_highlighted_column
    Product.with_connection do |connection|
      assert_equal "tinkick_test", connection.select_value("SELECT current_database()")
      assert_equal 0, connection.open_transactions
      raise "Refusing to replace an existing collision-test table" if connection.table_exists?(Product.table_name)
    end
    migration = CreateProducts.new
    begin
      migration.migrate(:up)
      Product.reset_column_information
      @product_id = Product.create!(name: "Red Apple").id
      yield
    ensure
      migration.migrate(:down) if Product.table_exists?
      Product.reset_column_information
    end
  end
end
