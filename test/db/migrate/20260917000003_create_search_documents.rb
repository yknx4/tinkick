# frozen_string_literal: true

class CreateSearchDocuments < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_documents do |table|
      table.text :title, null: false
      table.text :body, null: false
      table.text :category, null: false
    end

    add_index :tinkick_test_documents, :title, using: :tin
    add_index :tinkick_test_documents, :body, using: :tin
  end
end
