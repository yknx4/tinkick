# frozen_string_literal: true

class AddConversionCounts < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_products, :conversion_counts, :jsonb
  end
end
