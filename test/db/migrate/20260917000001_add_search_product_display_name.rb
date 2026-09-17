# frozen_string_literal: true

class AddSearchProductDisplayName < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_products, :display_name, :virtual,
      type: :text,
      as: "coalesce(name, '') || ' ' || coalesce(description, '')",
      stored: true

    add_index :tinkick_test_products, :display_name, using: :tin
  end
end
