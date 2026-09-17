# frozen_string_literal: true

class SearchDocument < ActiveRecord::Base
  self.table_name = "tinkick_test_documents"

  tinkick searchable: [:title, :body], default_fields: [:body]
end
