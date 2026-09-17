# frozen_string_literal: true

class AddSearchProductJsonIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :tinkick_test_products, "(metadata ->> 'title')", using: :tin, name: :tinkick_test_products_metadata_title_tin
    add_index :tinkick_test_products, "(metadata -> 'details' ->> 'title')", using: :tin, name: :tinkick_test_products_metadata_details_title_tin
    key = %q[quoted'key\"); DROP TABLE ignored; --]
    add_index :tinkick_test_products, "(metadata ->> #{connection.quote(key)})", using: :tin, name: :tinkick_test_products_metadata_quoted_tin
  end
end
