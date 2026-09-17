# frozen_string_literal: true

class AddSearchProductMetadata < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_products, :metadata, :jsonb
    add_index :tinkick_test_products, :metadata, using: :gin
  end
end
