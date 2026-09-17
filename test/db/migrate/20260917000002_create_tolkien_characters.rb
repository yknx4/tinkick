# frozen_string_literal: true

class CreateTolkienCharacters < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_characters do |table|
      table.text :name, null: false
      table.text :location, null: false
      table.text :race, null: false
      table.text :poem, null: false
    end

    [:name, :location, :race, :poem].each do |field|
      add_index :tinkick_test_characters, field, using: :tin
    end
  end
end
