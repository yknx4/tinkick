# frozen_string_literal: true

class EnableCitextForTests < ActiveRecord::Migration[8.0]
  def up
    enable_extension :citext
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Removing citext could invalidate existing application columns"
  end
end
