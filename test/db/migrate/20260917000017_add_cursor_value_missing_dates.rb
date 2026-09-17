# frozen_string_literal: true

class AddCursorValueMissingDates < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_cursor_values, :recorded_date, :date
  end
end
