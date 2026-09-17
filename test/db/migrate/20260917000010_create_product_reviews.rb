# frozen_string_literal: true

class CreateProductReviews < ActiveRecord::Migration[8.0]
  def change
    create_table :tinkick_test_reviews do |table|
      table.references :product, null: false
      table.text :body, null: false
    end
  end
end
