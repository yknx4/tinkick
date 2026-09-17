# frozen_string_literal: true

require_relative "../integration_helper"

class PhysicalPrimaryKeyFilterValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class CustomPrimaryKeyFilterValue < PhysicalPrimaryKeyFilterValue
  self.primary_key = "code"
end

class CustomPrimaryKeyFilterTest < TinkickIntegrationTest
  setup do
    @first_code = "00000000-0000-0000-0000-000000000001"
    @second_code = "00000000-0000-0000-0000-000000000002"
    attributes = { recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z", price: "1.25" }
    PhysicalPrimaryKeyFilterValue.create!(**attributes, id: -101, status: -102, name: "Northern beacon", code: @first_code)
    PhysicalPrimaryKeyFilterValue.create!(**attributes, id: -102, status: -101, name: "Southern beacon", code: @second_code)
  end

  def test_symbol_and_string_id_keys_use_the_model_primary_key
    assert_equal [@first_code], search(id: @first_code).map(&:id)
    assert_equal [@second_code], search("id" => @second_code).map(&:id)
    assert_equal [@first_code], search(code: @first_code).map(&:id)
  end

  def test_primary_key_filters_compose_membership_negation_groups_and_tin
    assert_equal [@first_code, @second_code], search(id: [@second_code, @first_code]).map(&:id).sort
    assert_equal [@second_code], search(id: { not: @first_code }).map(&:id)
    assert_equal [@first_code], search(_and: [{ id: @first_code }, { name: { prefix: "Northern" } }]).map(&:id)
    assert_empty Tinkick::Relation.new(CustomPrimaryKeyFilterValue, "southern", fields: [:name], misspellings: false,
      where: { id: @first_code }).to_a
  end

  def test_logical_id_takes_precedence_over_an_existing_physical_id_column
    model = Class.new(PhysicalPrimaryKeyFilterValue) { self.primary_key = "status" }
    result = Tinkick::Relation.new(model, "beacon", fields: [:name], misspellings: false, where: { id: -101 })

    assert_equal ["Southern beacon"], result.map(&:name)
    assert_equal [-101], result.map(&:id)
    assert_equal ["Northern beacon"], Tinkick::Relation.new(PhysicalPrimaryKeyFilterValue, "beacon",
      fields: [:name], misspellings: false, where: { id: -101 }).map(&:name)
  end

  private

  def search(conditions)
    Tinkick::Relation.new(CustomPrimaryKeyFilterValue, "beacon", fields: [:name], misspellings: false, where: conditions)
  end
end
