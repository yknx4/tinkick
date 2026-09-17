# frozen_string_literal: true

class CreateCursorValues < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_cursor_values do |table|
      table.text :name, null: false
      table.uuid :code, null: false
      table.date :recorded_on, null: false
      table.datetime :recorded_at, precision: 6, null: false
      table.decimal :price, precision: 30, scale: 10, null: false
      table.float :ratio, null: false, default: 0.0
      table.text :tags, array: true, null: false, default: []
    end

    add_index :tinkick_test_cursor_values, :name, using: :tin
  end
end
