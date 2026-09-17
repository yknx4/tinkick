# frozen_string_literal: true

class EnableMatchingExtensions < ActiveRecord::Migration[8.0]
  def up
    enable_extension "unaccent"
    enable_extension "fuzzystrmatch"
    enable_extension "pg_trgm"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Other tests or applications may use these extensions; keep them installed."
  end
end
