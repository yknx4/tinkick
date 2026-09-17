# frozen_string_literal: true

require_relative "../../lib/tinkick/aggregations"
require_relative "../integration_helper"

class ScopedAggregationProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  default_scope { where(id: 10_001..10_012) }
end

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
    assert_raises(ArgumentError) { aggregate(name: { min_doc_count: -1 }) }
    assert_raises(ArgumentError) { aggregate(name: { script: "arbitrary SQL" }) }

    assert_empty aggregate(name: { where: { name: "amber' OR TRUE --" } }).fetch("name").fetch("buckets")
    assert_equal 8, @scope.count
  end

  def test_scalar_metrics_aggregate_the_entire_matching_scope
    result = Tinkick::Aggregations.new(SearchProduct, @scope.limit(1).offset(3)).call(
      low: { min: { field: :id } },
      high: { max: { field: :id } },
      total: { sum: { field: :id } },
      average: { avg: { field: :id } },
      categories: { cardinality: { field: :name } },
    )

    assert_equal({ "value" => 10_001.0 }, result.fetch("low"))
    assert_equal({ "value" => 10_008.0 }, result.fetch("high"))
    assert_equal({ "value" => 80_036.0 }, result.fetch("total"))
    assert_equal({ "value" => 10_004.5 }, result.fetch("average"))
    assert_equal({ "value" => 4 }, result.fetch("categories"))
    refute @scope.loaded?
  end

  def test_array_metrics_keep_numeric_duplicates_and_ignore_nulls
    SearchProduct.where(id: 10_001).update_all(ratings: [1, 1, nil])
    result = aggregate(
      low: { min: { field: :ratings } },
      high: { max: { field: :ratings } },
      total: { sum: { field: :ratings } },
      average: { avg: { field: :ratings } },
      distinct_values: { cardinality: { field: :ratings } },
    )

    assert_equal 1.0, result.fetch("low").fetch("value")
    assert_equal 80.0, result.fetch("high").fetch("value")
    assert_equal 387.0, result.fetch("total").fetch("value")
    assert_equal 24.1875, result.fetch("average").fetch("value")
    assert_equal 15, result.fetch("distinct_values").fetch("value")
  end

  def test_empty_metric_scopes_and_missing_array_values
    [@scope.none, @scope].each do |scope|
      SearchProduct.where(id: 10_001..10_008).update_all(ratings: [nil])
      result = Tinkick::Aggregations.new(SearchProduct, scope).call(
        low: { min: { field: :ratings } },
        high: { max: { field: :ratings } },
        total: { sum: { field: :ratings } },
        average: { avg: { field: :ratings } },
        distinct_values: { cardinality: { field: :ratings } },
      )

      assert_nil result.fetch("low").fetch("value")
      assert_nil result.fetch("high").fetch("value")
      assert_nil result.fetch("average").fetch("value")
      assert_equal 0.0, result.fetch("total").fetch("value")
      assert_equal 0, result.fetch("distinct_values").fetch("value")
    end
  end

  def test_metric_filters_and_document_identity_are_preserved
    scope = @scope.joins("CROSS JOIN generate_series(1, 2) AS duplicate_rows")
    result = Tinkick::Aggregations.new(SearchProduct, scope).call(total: { sum: { field: :ratings }, where: { name: "amber" } })

    assert_equal({ "value" => 66.0, "doc_count" => 3 }, result.fetch("total"))
    assert_raises(Tinkick::InvalidQueryError) { aggregate(total: { sum: { field: :name } }) }
    assert_raises(Tinkick::MissingFieldError) { aggregate(total: { sum: { field: "id); DROP TABLE x --" } }) }
    assert_raises(ArgumentError) { aggregate(total: { sum: { field: :id }, avg: { field: :id } }) }
  end

  def test_zero_count_terms_include_dictionary_values_outside_the_query
    SearchProduct.where(id: 10_012).update_all(name: "zinc")
    dictionary = SearchProduct.where(id: 10_001..10_012).order(:id).limit(1).offset(1)
    evaluator = Tinkick::Aggregations.new(SearchProduct, @scope, dictionary_scope: dictionary)
    result = evaluator.call(name: { min_doc_count: 0, order: { _count: :asc }, limit: 2 }).fetch("name")

    assert_equal [{ "key" => "zinc", "doc_count" => 0 }, { "key" => "violet", "doc_count" => 1 }], result.fetch("buckets")
    assert_equal 7, result.fetch("sum_other_doc_count")
    assert_equal 0, result.fetch("doc_count_error_upper_bound")
    refute dictionary.loaded?
  end

  def test_zero_count_dictionary_preserves_model_scope_and_ignores_aggregation_filters
    scope = ScopedAggregationProduct.where("description ==> ?", "voyage")
    result = Tinkick::Aggregations.new(ScopedAggregationProduct, scope)
      .call(name: { min_doc_count: 0, where: { tags: "warm" } }).fetch("name")

    assert_equal [{ "key" => "amber", "doc_count" => 3 }, { "key" => "blue", "doc_count" => 1 }, { "key" => "copper", "doc_count" => 0 }, { "key" => "violet", "doc_count" => 0 }], result.fetch("buckets")
    assert_equal 4, result.fetch("doc_count")
    assert_equal 0, result.fetch("sum_other_doc_count")

    empty_result = Tinkick::Aggregations.new(ScopedAggregationProduct, scope.none)
      .call(name: { min_doc_count: 0 }).fetch("name")
    assert_equal ["amber", "blue", "copper", "violet"], empty_result.fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal [0], empty_result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }.uniq
  end

  def test_zero_count_array_dictionary_omits_nulls_and_counts_each_document_once
    result = Tinkick::Aggregations.new(SearchProduct, @scope, dictionary_scope: SearchProduct.where(id: 10_001..10_012))
      .call(tags: { min_doc_count: 0, order: { _key: :asc } }).fetch("tags")

    assert_equal [{ "key" => "cool", "doc_count" => 2 }, { "key" => "outside", "doc_count" => 0 }, { "key" => "shared", "doc_count" => 6 }, { "key" => "warm", "doc_count" => 4 }], result.fetch("buckets")
    assert_equal 0, result.fetch("sum_other_doc_count")

    SearchProduct.where(id: 10_001..10_012).update_all(tags: [nil])
    assert_empty aggregate(tags: { min_doc_count: 0 }).fetch("tags").fetch("buckets")
  end

  private

  def aggregate(spec)
    Tinkick::Aggregations.new(SearchProduct, @scope).call(spec)
  end
end
