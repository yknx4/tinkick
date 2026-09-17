# frozen_string_literal: true

class CreateSearchCreatures < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_creatures do |table|
      table.string :type
      table.text :name, null: false
      table.text :category, null: false
      table.integer :amount, null: false
      table.integer :ratings, array: true, default: [], null: false
      table.datetime :recorded_at, null: false
    end

    add_index :tinkick_test_creatures, :name, using: :tin
  end
end
