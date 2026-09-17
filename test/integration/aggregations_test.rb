# frozen_string_literal: true

require_relative "../../lib/tinkick/aggregations"
require_relative "../integration_helper"

class AggregationsTest < TinkickIntegrationTest
  setup do
    categories = ["amber", "amber", "amber", "blue", "blue", "copper", "copper", "violet", "amber", "blue", "copper", "violet"]
    categories.each_with_index do |category, index|
      tags = if index < 4
        ["shared", "warm", "warm"]
      elsif index < 6
        ["shared", "cool"]
      elsif index == 6
        []
      elsif index == 7
        [nil]
      else
        ["outside", "shared"]
      end
      SearchProduct.create!(id: 10_001 + index, name: category, description: index < 8 ? "Voyage atlas" : "Archive ledger", tags: tags, ratings: [index + 1, (index + 1) * 10])
    end
    @scope = SearchProduct.where("description ==> ?", "voyage")
  end

  def test_terms_use_matching_documents_with_count_order_and_key_ties
    result = aggregate([:name]).fetch("name")

    assert_equal [{ "key" => "amber", "doc_count" => 3 }, { "key" => "blue", "doc_count" => 2 }, { "key" => "copper", "doc_count" => 2 }, { "key" => "violet", "doc_count" => 1 }], result.fetch("buckets")
    assert_equal 0, result.fetch("sum_other_doc_count")
    assert_equal 0, result.fetch("doc_count_error_upper_bound")
  end

  def test_limits_buckets_in_sql_without_loading_model_records
    instantiated = []
    result = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      result = Tinkick::Aggregations.new(SearchProduct, @scope.order(:id).limit(1).offset(4)).call(categories: { field: :name, limit: 2 })
    end

    assert_equal ["amber", "blue"], result.fetch("categories").fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal 3, result.fetch("categories").fetch("sum_other_doc_count")
    assert_empty instantiated
    refute @scope.loaded?
  end

  def test_terms_support_key_and_count_ordering
    assert_equal ["violet", "copper", "blue", "amber"], aggregate(name: { order: { _key: :desc } }).fetch("name").fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal ["violet", "blue", "copper", "amber"], aggregate(name: { order: [{ "_count" => "asc" }, { "_key" => "asc" }] }).fetch("name").fetch("buckets").map { |bucket| bucket.fetch("key") }
  end

  def test_minimum_document_count_and_per_aggregation_filters
    result = aggregate(name: { min_doc_count: 2 }, selected: { field: :name, where: { tags: "warm" } })

    assert_equal ["amber", "blue", "copper"], result.fetch("name").fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal [{ "key" => "amber", "doc_count" => 3 }, { "key" => "blue", "doc_count" => 1 }], result.fetch("selected").fetch("buckets")
    assert_equal 4, result.fetch("selected").fetch("doc_count")
  end

  def test_array_terms_count_each_document_once_per_value
    result = aggregate(tags: { limit: 2 }).fetch("tags")

    assert_equal [{ "key" => "shared", "doc_count" => 6 }, { "key" => "warm", "doc_count" => 4 }], result.fetch("buckets")
    assert_equal 2, result.fetch("sum_other_doc_count")
  end

  def test_nulls_are_omitted_but_empty_strings_are_terms
    SearchProduct.where(id: 10_001).update_all(description: nil)
    SearchProduct.where(id: 10_002..10_003).update_all(description: "")
    scope = SearchProduct.where(id: 10_001..10_003)

    assert_equal [{ "key" => "", "doc_count" => 2 }], Tinkick::Aggregations.new(SearchProduct, scope).call([:description]).fetch("description").fetch("buckets")
    assert_equal({ "doc_count_error_upper_bound" => 0, "sum_other_doc_count" => 0, "buckets" => [] }, Tinkick::Aggregations.new(SearchProduct, scope.none).call([:name]).fetch("name"))
  end

  def test_invalid_identifiers_options_and_order_cannot_change_sql
    assert_raises(Tinkick::MissingFieldError) { aggregate(["name) OR TRUE --"]) }
    assert_raises(ArgumentError) { aggregate(name: { order: { "_key; DROP TABLE x" => "asc" } }) }
    assert_raises(ArgumentError) { aggregate(name: { order: { _key: "desc; DROP TABLE x" } }) }
    assert_raises(ArgumentError) { aggregate(name: { limit: 0 }) }
    assert_raises(ArgumentError) { aggregate(name: { min_doc_count: 0 }) }
    assert_raises(ArgumentError) { aggregate(name: { script: "arbitrary SQL" }) }

    assert_empty aggregate(name: { where: { name: "amber' OR TRUE --" } }).fetch("name").fetch("buckets")
    assert_equal 8, @scope.count
  end

  private

  def aggregate(spec)
    Tinkick::Aggregations.new(SearchProduct, @scope).call(spec)
  end
end
