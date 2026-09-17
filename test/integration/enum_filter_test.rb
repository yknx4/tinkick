# frozen_string_literal: true

require_relative "../integration_helper"

class EnumFilterValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
  enum :status, { published: 0, draft: 1 }
end

class NumericLabelEnumFilterValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
  enum :status, { "0" => 7, "1" => 9 }, scopes: false, instance_methods: false
end

class TextEnumFilterProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  enum :description, { published: "P", draft: "D" }
end

class EnumFilterTest < TinkickIntegrationTest
  setup do
    @attributes = { recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z", price: "1.25",
      code: "00000000-0000-0000-0000-000000000001" }
    @published = EnumFilterValue.create!(**@attributes, name: "Published beacon", status: :published)
    @draft = EnumFilterValue.create!(**@attributes, name: "Draft beacon", status: :draft)
    @scope = EnumFilterValue.where(id: [@published.id, @draft.id])
  end

  def test_known_string_and_symbol_labels_match_serialized_search_data
    assert_equal "published", @published.serializable_hash.fetch("status")
    assert_equal ["Published beacon"], names(status: "published")
    assert_equal ["Draft beacon"], names("status" => :draft)
    assert_equal [@published.id], Tinkick::Relation.new(EnumFilterValue, "beacon", fields: [:name],
      misspellings: false, where: { status: :published }).map(&:id)
  end

  def test_unknown_labels_and_backing_ordinals_do_not_match
    ["unknown", :unknown, 0, 1, "0", "1"].each do |value|
      assert_empty names(status: value), value.inspect
    end
    assert_equal ["Draft beacon", "Published beacon"], names(status: { not: "unknown" })
    assert_empty names(status: nil)
  end

  def test_membership_all_negation_and_groups_resolve_each_label
    assert_equal ["Draft beacon", "Published beacon"], names(status: { in: [:published, "draft", "unknown"] })
    assert_equal ["Published beacon"], names(status: [0, :published])
    assert_equal ["Published beacon"], names(status: { all: [:published, "published"] })
    assert_empty names(status: { all: [:published, :draft] })
    assert_empty names(status: { all: [:published, "unknown"] })
    assert_equal ["Draft beacon"], names(status: { not: [:published, "unknown"] })
    assert_equal ["Draft beacon"], names(_not: { status: :published })
    assert_equal ["Published beacon"], names(_or: [{ status: "unknown" }, { status: :published }])
  end

  def test_numeric_keyword_values_match_numeric_labels_instead_of_backing_values
    zero = NumericLabelEnumFilterValue.create!(**@attributes, name: "Zero label", status: "0")
    one = NumericLabelEnumFilterValue.create!(**@attributes, name: "One label", status: "1")
    scope = NumericLabelEnumFilterValue.where(id: [zero.id, one.id])
    filter = Tinkick::Filter.new(NumericLabelEnumFilterValue)

    assert_equal [zero.id], filter.apply(scope, status: 0).ids
    assert_equal [one.id], filter.apply(scope, status: "1").ids
    assert_equal [zero.id, one.id].sort, filter.apply(scope, status: [0, 1]).ids.sort
    assert_empty filter.apply(scope, status: 7)
    assert_empty filter.apply(scope, status: 0.0)
  end

  def test_text_backed_enums_do_not_confuse_unknown_labels_with_null
    published = TextEnumFilterProduct.create!(name: "Published text", description: :published)
    draft = TextEnumFilterProduct.create!(name: "Draft text", description: :draft)
    missing = TextEnumFilterProduct.create!(name: "Missing text", description: nil)
    scope = TextEnumFilterProduct.where(id: [published.id, draft.id, missing.id])
    filter = Tinkick::Filter.new(TextEnumFilterProduct)

    assert_equal [published.id], filter.apply(scope, description: :published).ids
    assert_empty filter.apply(scope, description: "P")
    assert_empty filter.apply(scope, description: "unknown")
    assert_equal [missing.id], filter.apply(scope, description: nil).ids
    assert_equal [missing.id], filter.apply(scope, description: { exists: false }).ids
    assert_equal [published.id, draft.id].sort, filter.apply(scope, description: { not: nil }).ids.sort
    assert_equal scope.ids.sort, filter.apply(scope, description: { not: "unknown" }).ids.sort
    assert_equal [published.id, missing.id].sort, filter.apply(scope, description: [nil, :published, "unknown"]).ids.sort
  end

  private

  def names(conditions)
    Tinkick::Filter.new(EnumFilterValue).apply(@scope, conditions).order(:name).pluck(:name)
  end
end
