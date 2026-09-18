# frozen_string_literal: true

require_relative "../integration_helper"

class ActiveRecordCompositionTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  def test_sql_and_arel_scopes_are_captured_before_lazy_search
    table = Product.arel_table
    search = Product.where("name = ?", "Red Apple").where(table[:id].gt(0))
      .tinkick_search("fruit", fields: [:description], misspellings: false)

    assert_equal ["Red Apple"], search.map(&:name)
    assert_equal 1, search.total_count
    assert_equal ["Red Apple"], search.except(:order).map(&:name)
    assert_equal ["Red Apple"], search.only(:fields, :misspellings).map(&:name)
  end

  def test_merge_accepts_a_model_scope_without_mutating_the_original_search
    original = Product.tinkick_search("fruit", fields: [:description], misspellings: false)
    scoped = original.merge(Product.where(name: "Green Pear"))

    assert_equal ["Green Pear"], scoped.map(&:name)
    assert_equal 1, scoped.total_count
    assert_equal 2, original.total_count
    assert_raises(ArgumentError) { original.merge(SearchProduct.all) }
  end

  def test_native_relation_supports_sql_arel_joins_and_ctes
    search = Product.tinkick_search("fruit", fields: [:description], misspellings: false)
    native = search.to_relation
    assert_kind_of ActiveRecord::Relation, native
    refute search.loaded?

    scope = native.where(Product.arel_table[:name].eq("Red Apple"))
      .joins("INNER JOIN (SELECT 'Red Apple'::text AS name) AS selected ON selected.name = tinkick_test_products.name")
    assert_equal ["Red Apple"], scope.map(&:name)
    assert scope.first.has_attribute?("_tinkick_score")

    candidates = native.except(:limit, :offset, :order)
    outer = Product.unscoped.with(candidates: candidates).from("candidates AS tinkick_test_products")
      .where("_tinkick_score >= ?", 0).order(:id)
    assert_equal Product.order(:id).ids, outer.map(&:id)
    assert_equal 2, outer.count
  end

  def test_native_relation_does_not_expose_the_countless_probe_row
    search = Product.tinkick_search("fruit", fields: [:description], misspellings: false, countless: true, limit: 1)

    assert_equal 1, search.to_relation.to_a.length
    assert search.has_next_page?
    assert_equal 2, search.total_count
  end

  def test_fuzzy_threshold_and_aggregations_respect_the_incoming_scope
    search = Product.where(name: "Green Pear").tinkick_search("apple", fields: [:name],
      misspellings: { below: 5 }, aggs: [:name], smart_aggs: false)

    assert_empty search.to_a
    assert_equal 0, search.total_count
    assert_empty search.aggregations.fetch("name").fetch("buckets")
  end
end
