# frozen_string_literal: true

class CreateSearchProducts < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_products do |table|
      table.text :name, null: false
      table.text :description
    end

    add_index :tinkick_test_products, :name, using: :tin
    add_index :tinkick_test_products, :description, using: :tin
  end
end
