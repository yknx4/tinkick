# frozen_string_literal: true

require_relative "../integration_helper"

class QueryBlockTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  def test_keyword_hook_filters_before_pagination_and_counts
    transform = lambda do |relation|
      assert_nil relation.limit_value
      assert_nil relation.offset_value
      relation.where(Product.arel_table[:name].eq("Green Pear"))
    end
    search = Product.search("fruit", fields: [:description], misspellings: false, limit: 1, block: transform)
    assert_equal ["Green Pear"], search.map(&:name)
    assert_equal 1, search.total_count
    assert_equal ["Green Pear"], search.except(:order).map(&:name)
  end

  def test_ruby_hook_is_forwarded_by_module_search_and_preserves_custom_scores
    search = Tinkick.search("fruit", model: Product, fields: [:description], misspellings: false, load: false) do |relation|
      relation.reselect("tinkick_test_products.*", "42.0 AS _tinkick_score").reorder(name: :desc)
    end
    assert_equal ["Red Apple", "Green Pear"], search.map(&:name)
    assert_equal [42.0, 42.0], search.with_score.map { |_record, score| score }
    assert_equal [42.0, 42.0], search.select(:name).with_score.map { |_record, score| score }
    assert_equal ["Red Apple", "Green Pear"], search.pluck(:name)
  end

  def test_hook_applies_to_fuzzy_threshold_and_aggregations
    search = Product.search("apple", fields: [:name], misspellings: { below: 1 }, aggs: [:name],
      block: ->(relation) { relation.where(name: "Green Pear") })
    assert search.misspellings?
    assert_empty search.to_a
    assert_equal 0, search.total_count
    assert_empty search.aggregations.fetch("name").fetch("buckets")
  end

  def test_cte_hook_counts_rows_after_grouping_and_before_pagination
    search = Product.where("id > ?", 0).search("fruit", fields: [:description], misspellings: false, limit: 1) do |relation|
      Product.unscoped.with(candidates: relation.except(:order)).from("candidates AS tinkick_test_products")
        .where(name: "Green Pear").order(:id)
    end
    assert_equal ["Green Pear"], search.map(&:name)
    assert_equal 1, search.total_count
  end

  def test_countless_and_keyset_keep_their_pagination_contract
    first = Product.search("fruit", fields: [:description], misspellings: false, keyset: true, order: { id: :asc }, limit: 1,
      block: ->(relation) { relation.reorder(id: :desc) })
    assert first.has_next_page?
    second = Product.search("fruit", fields: [:description], misspellings: false, keyset: true, order: { id: :asc }, limit: 1,
      after: first.next_cursor, block: ->(relation) { relation.reorder(id: :desc) })
    assert_equal Product.order(:id).ids, first.map(&:id) + second.map(&:id)
    refute second.has_next_page?
  end

  def test_invalid_or_ambiguous_hooks_fail_clearly
    error = assert_raises(ArgumentError) { Product.search("*", block: ->(relation) { relation }) { |relation| relation } }
    assert_match(/either/, error.message)
    [nil, [], SearchProduct.all].each do |value|
      error = assert_raises(ArgumentError) { Product.search("*", block: ->(_relation) { value }).to_a }
      assert_match(/return an Active Record relation/, error.message)
    end
  end
end
