# frozen_string_literal: true

class EnableTin < ActiveRecord::Migration[8.0]
  def change
    enable_extension "tin" unless extension_enabled?("tin")
  end
end
