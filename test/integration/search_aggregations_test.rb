# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class SearchAggregationsTest < TinkickIntegrationTest
  class TravelProduct < SearchProduct
    extend Tinkick::Model
    tinkick searchable: [:description]
  end

  setup do
    SearchProduct.delete_all
    regions = %w[Lindon Lindon Lindon Gondor Gondor Moria Moria Shire]
    regions.each_with_index do |region, index|
      SearchProduct.create!(name: region, description: "Voyage #{index}: route maps and lodging near #{region}", ratings: [index + 1])
    end
    SearchProduct.create!(name: "Rivendell", description: "Unrelated collection of bread recipes", ratings: [90])
  end

  def test_model_aggregations_cover_all_matches_without_loading_matching_models
    search = TravelProduct.search("voyage", aggs: [:name], limit: 1, misspellings: false)
    instantiations = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      assert_equal([3, 2, 2, 1], search.aggs.fetch("name").fetch("buckets").map { |bucket| bucket.fetch("doc_count") })
      assert_empty(instantiations)
    end
    assert_equal(1, search.size)
    assert_equal(8, search.total_count)
    refute_includes(search.aggs.fetch("name").fetch("buckets").map { |bucket| bucket.fetch("key") }, "Rivendell")
  end

  def test_smart_facets_exclude_their_own_filter_without_changing_result_filters
    search = TravelProduct.search("voyage", where: { name: "Lindon" }, aggs: [:name], misspellings: false)

    assert_equal(["Lindon"], search.map(&:name).uniq)
    assert_equal(4, search.aggs.fetch("name").fetch("buckets").size)
    ordinary = TravelProduct.search("voyage", where: { name: "Lindon" }, aggs: [:name], smart_aggs: false, misspellings: false)
    assert_equal([{ "key" => "Lindon", "doc_count" => 3 }], ordinary.aggs.fetch("name").fetch("buckets"))
  end

  def test_fluent_aggregations_merge_and_reuse_their_cached_results
    base = TravelProduct.search("voyage", misspellings: false)
    search = base.aggs(:name).aggs(total: { sum: { field: :ratings } }).smart_aggs(false)

    assert_nil(base.aggs)
    assert_equal(36.0, search.aggs.fetch("total").fetch("value"))
    assert_equal(4, search.aggs.fetch("name").fetch("buckets").size)
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { search.aggs }
    assert_empty(statements)
    assert_raises(Tinkick::Error) { search.aggs!(:ratings) }
  end

  def test_filtered_aggregation_envelopes_match_the_flat_and_raw_interfaces
    search = TravelProduct.search("voyage", aggs: { name: { where: { name: "Gondor" } } }, misspellings: false)
    expected = [{ "key" => "Gondor", "doc_count" => 2 }]

    assert_equal(2, search.aggs.fetch("name").fetch("doc_count"))
    assert_equal(expected, search.aggs.fetch("name").fetch("buckets"))
    assert_equal(expected, search.aggregations.fetch("name").fetch("name").fetch("buckets"))
    assert_equal(2, search.aggregations.fetch("name").fetch("doc_count"))
    assert_equal(8, search.total_count)
  end
end
