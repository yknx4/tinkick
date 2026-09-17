# frozen_string_literal: true

require_relative "../integration_helper"

class CanonicalEnumFilterProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  enum :description, { published: "P", live: "P", draft: "D", unclassified: nil }
end

class NullableEnumFilterProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  enum :description, { published: "P", draft: "D" }
end

class CanonicalEnumFilterTest < TinkickIntegrationTest
  setup do
    @published = CanonicalEnumFilterProduct.create!(name: "Published canonical", description: :live).reload
    @draft = CanonicalEnumFilterProduct.create!(name: "Draft canonical", description: :draft)
    @unclassified = CanonicalEnumFilterProduct.create!(name: "Unclassified canonical", description: :unclassified).reload
    @unknown = SearchProduct.create!(name: "Unknown backing", description: "REMOVED")
    @scope = CanonicalEnumFilterProduct.where(id: [@published.id, @draft.id, @unclassified.id, @unknown.id])
    @filter = Tinkick::Filter.new(CanonicalEnumFilterProduct)
  end

  def test_duplicate_backing_values_use_the_first_deserialized_label
    assert_equal "published", @published.serializable_hash.fetch("description")
    assert_equal [@published.id], ids(description: :published)
    assert_empty ids(description: :live)
    assert_empty ids(description: { all: [:published, :live] })
    assert_equal @scope.ids.sort, ids(description: { not: :live })
  end

  def test_a_label_mapped_to_sql_null_is_present_and_unknown_backing_is_missing
    assert_equal "unclassified", @unclassified.serializable_hash.fetch("description")
    assert_nil CanonicalEnumFilterProduct.find(@unknown.id).serializable_hash.fetch("description")
    assert_equal [@unclassified.id], ids(description: :unclassified)
    assert_equal [@unknown.id], ids(description: nil)
    assert_equal [@unknown.id], ids(description: { exists: false })
    assert_equal [@published.id, @draft.id, @unclassified.id].sort, ids(description: { exists: true })
    assert_equal [@unknown.id, @unclassified.id].sort, ids(description: [nil, :unclassified])
    assert_equal [@published.id, @draft.id, @unclassified.id].sort, ids(description: { not: nil })
  end

  def test_without_a_null_label_both_sql_null_and_unknown_backing_are_missing
    scope = NullableEnumFilterProduct.where(id: @scope.ids)
    filter = Tinkick::Filter.new(NullableEnumFilterProduct)

    assert_equal [@unclassified.id, @unknown.id].sort, filter.apply(scope, description: nil).ids.sort
    assert_equal [@unclassified.id, @unknown.id].sort, filter.apply(scope, description: { exists: false }).ids.sort
    assert_equal [@published.id, @draft.id].sort, filter.apply(scope, description: { exists: true }).ids.sort
    assert_equal [@published.id, @draft.id].sort, filter.apply(scope, description: { not: nil }).ids.sort
  end

  private

  def ids(conditions)
    @filter.apply(@scope, conditions).ids.sort
  end
end
