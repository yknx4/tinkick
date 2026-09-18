# frozen_string_literal: true

class CreateCatalogEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_catalog_entries do |table|
      table.text :title, null: false
      table.text :creator_name, null: false
      table.virtual :search_text, type: :text, as: "title || ' ' || creator_name", stored: true
      table.text :normalized_title, null: false
      table.text :group_key, null: false
      table.bigint :collection_id, null: false
      table.integer :status, null: false, default: 0
      [:approved_levels, :rejected_levels, :pending_levels].each do |field|
        table.integer field, array: true, default: [], null: false
      end
      [:restricted_content, :has_image, :has_verified_identifier, :has_creator, :has_extended_metadata].each do |field|
        table.boolean field, null: false, default: false
      end
      table.integer :minimum_age, null: false, default: 0
      table.integer :popularity, null: false, default: 0
    end
    [:title, :creator_name, :search_text].each do |field|
      add_index :tinkick_test_catalog_entries, field, using: :tin
    end
    add_index :tinkick_test_catalog_entries, :collection_id
  end
end
