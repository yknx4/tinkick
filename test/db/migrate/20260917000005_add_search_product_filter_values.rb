# frozen_string_literal: true

class AddSearchProductFilterValues < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_products, :tags, :text, array: true
    add_column :tinkick_test_products, :ratings, :integer, array: true
    add_index :tinkick_test_products, :tags, using: :gin
    add_index :tinkick_test_products, :ratings, using: :gin
  end
end
