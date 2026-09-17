# frozen_string_literal: true

class TolkienCharacter < ActiveRecord::Base
  self.table_name = "tinkick_test_characters"

  tinkick searchable: [:name, :location, :race, :poem], default_fields: [:name, :poem]
end
