# frozen_string_literal: true

class AddCursorValueRecordedTimes < ActiveRecord::Migration[8.0]
  def change
    add_column :tinkick_test_cursor_values, :recorded_times, :datetime, array: true
  end
end
