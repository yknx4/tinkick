# frozen_string_literal: true

class AddCursorValueStatus < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_cursor_values, :status, :integer, null: false, default: 0
  end
end
