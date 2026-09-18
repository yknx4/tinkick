# frozen_string_literal: true

class CatalogEntry < ActiveRecord::Base
  self.table_name = "tinkick_test_catalog_entries"

  enum :status, { pending: 0, review: 1, approved: 2, rejected: 3 }
  has_many :editions, class_name: "CatalogEntry", primary_key: :group_key, foreign_key: :group_key
  tinkick searchable: [:title, :creator_name, :search_text], default_fields: [:title]
end
