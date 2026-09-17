# frozen_string_literal: true

require_relative "../integration_helper"

class HistogramValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class HistogramsTest < TinkickIntegrationTest
  setup do
    [-12.5, -10, -0.1, 0, 9.9, 20, 21].each_with_index do |price, index|
      HistogramValue.create!(name: "Histogram measurement", code: format("00000000-0000-0000-0000-%012d", index),
        recorded_on: Date.new(2026, 1, 1), recorded_at: Time.utc(2026, 1, 1), price: price)
    end
    HistogramValue.create!(name: "Unrelated archive", code: "00000000-0000-0000-0000-000000000099",
      recorded_on: Date.new(2026, 1, 1), recorded_at: Time.utc(2026, 1, 1), price: 100)
    @scope = HistogramValue.where("name ==> ?", "measurement")
  end

  def test_public_histogram_counts_matching_documents_and_fills_empty_buckets
    search = Tinkick::Relation.new(HistogramValue, "measurement", fields: [:name], misspellings: false, limit: 1,
      aggs: { prices: { histogram: { field: :price, interval: 10 } } })
    buckets = search.aggs.fetch("prices").fetch("buckets")

    assert_equal [-20.0, -10.0, 0.0, 10.0, 20.0], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 2, 2, 0, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_fractional_intervals_offsets_and_count_thresholds
    buckets = histogram(interval: 2.5, min_doc_count: 1).fetch("buckets")

    assert_equal [-12.5, -10.0, -2.5, 0.0, 7.5, 20.0], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 1, 1, 1, 1, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
    buckets = histogram(interval: 10, offset: 5, min_doc_count: 2).fetch("buckets")
    assert_equal [-15.0, -5.0, 15.0], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [2, 2, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal buckets, histogram(interval: 10, offset: -5, min_doc_count: 2).fetch("buckets")
  end

  def test_keyed_histograms_retain_numeric_keys_and_order_ties_by_key
    buckets = histogram(interval: 10, min_doc_count: 1, keyed: true, order: { _count: :desc }).fetch("buckets")

    assert_equal ["-10.0", "0.0", "20.0", "-20.0"], buckets.keys
    assert_equal({ "key" => -10.0, "doc_count" => 2 }, buckets.fetch("-10.0"))
    descending = histogram(interval: 10, order: { _key: :desc }).fetch("buckets")
    assert_equal [20.0, 10.0, 0.0, -10.0, -20.0], descending.map { |bucket| bucket.fetch("key") }
  end

  def test_array_values_count_each_document_once_per_bucket_and_ignore_missing_values
    [[1, 1, 2, 9, 11], [3, 12], [25], [], nil, [nil]].each_with_index do |ratings, index|
      SearchProduct.create!(name: "Histogram array", description: "Measured samples", ratings: ratings, id: 11_001 + index)
    end
    scope = SearchProduct.where("description ==> ?", "measured").joins("CROSS JOIN generate_series(1, 2) AS duplicate_rows")
    result = Tinkick::Aggregations.new(SearchProduct, scope).call(samples: { histogram: { field: :ratings, interval: 10 } })

    assert_equal [{ "key" => 0.0, "doc_count" => 2 }, { "key" => 10.0, "doc_count" => 2 }, { "key" => 20.0, "doc_count" => 1 }],
      result.fetch("samples").fetch("buckets")
    refute scope.loaded?

    bounded = Tinkick::Aggregations.new(SearchProduct, scope).call(samples: { histogram: { field: :ratings, interval: 10, hard_bounds: { min: 10, max: 20 } } })
    assert_equal [{ "key" => 10.0, "doc_count" => 2 }, { "key" => 20.0, "doc_count" => 1 }], bounded.fetch("samples").fetch("buckets")
  end

  def test_filters_apply_before_bucketing_without_instantiating_records
    instantiated = []
    result = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      result = Tinkick::Aggregations.new(HistogramValue, @scope.limit(1)).call(prices: {
        histogram: { field: :price, interval: 10 }, where: { price: { gte: 0 } },
      }).fetch("prices")
    end

    assert_equal [2, 0, 2], result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    assert_equal 4, result.fetch("doc_count")
    assert_empty instantiated
    assert_empty Tinkick::Aggregations.new(HistogramValue, HistogramValue.none)
      .call(prices: { histogram: { field: :price, interval: 10 } }).fetch("prices").fetch("buckets")
  end

  def test_histograms_validate_options_and_numeric_fields
    [{}, { interval: 0 }, { interval: -1 }, { interval: Float::INFINITY }, { interval: 10, offset: Float::NAN },
      { interval: 10, min_doc_count: -1 }, { interval: 10, min_doc_count: 1.5 }, { interval: 10, keyed: "true" },
      { interval: 10, order: { price: :asc } }, { interval: 10, script: "arbitrary" }].each do |options|
      assert_raises(ArgumentError) { histogram(**options) }
    end
    assert_raises(Tinkick::InvalidQueryError) { histogram(field: :name, interval: 10) }
    assert_raises(Tinkick::MissingFieldError) { histogram(field: :unknown, interval: 10) }
    assert_raises(ArgumentError) { Tinkick::Aggregations.new(HistogramValue, @scope).call(prices: { histogram: { interval: 10 }, ranges: [{}] }) }
  end

  def test_histogram_settings_must_be_nested
    { field: :price, order: { _key: :desc }, min_doc_count: 2, limit: 1 }.each do |key, value|
      error = assert_raises(ArgumentError) do
        Tinkick::Aggregations.new(HistogramValue, @scope).call(prices: { histogram: { field: :price, interval: 10 }, key => value })
      end

      assert_includes error.message, "inside histogram:"
    end
  end

  def test_extended_bounds_expand_empty_buckets_without_filtering_matching_values
    buckets = histogram(interval: 10, extended_bounds: { min: -30, max: 40 }).fetch("buckets")

    assert_equal [-30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 30.0, 40.0], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 1, 2, 2, 0, 2, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal histogram(interval: 10), histogram(interval: 10, extended_bounds: { min: 0, max: 10 })
    assert_equal histogram(interval: 10, min_doc_count: 1), histogram(interval: 10, min_doc_count: 1, extended_bounds: { min: -30, max: 40 })
  end

  def test_extended_bounds_generate_buckets_for_empty_scopes_and_allow_partial_bounds
    evaluator = Tinkick::Aggregations.new(HistogramValue, HistogramValue.none)
    buckets = evaluator.call(prices: { histogram: { field: :price, interval: 10, extended_bounds: { min: -9, max: 19 } } })
      .fetch("prices").fetch("buckets")

    assert_equal [{ "key" => -10.0, "doc_count" => 0 }, { "key" => 0.0, "doc_count" => 0 }, { "key" => 10.0, "doc_count" => 0 }], buckets
    [{ min: 0 }, { max: 20 }, { min: nil, max: nil }, {}].each do |bounds|
      assert_empty evaluator.call(prices: { histogram: { field: :price, interval: 10, extended_bounds: bounds } }).fetch("prices").fetch("buckets")
    end
    partial = histogram(interval: 10, extended_bounds: { max: 40 }).fetch("buckets")
    assert_equal [-20.0, -10.0, 0.0, 10.0, 20.0, 30.0, 40.0], partial.map { |bucket| bucket.fetch("key") }
  end

  def test_hard_bounds_filter_numeric_bucket_ordinals_with_inclusive_endpoints
    buckets = histogram(interval: 10, hard_bounds: { min: -10, max: 20 }).fetch("buckets")

    assert_equal [-10.0, 0.0, 10.0, 20.0], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [2, 2, 0, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
    shifted = histogram(interval: 10, offset: 5, hard_bounds: { min: 0, max: 10 }).fetch("buckets")
    assert_equal [{ "key" => 5.0, "doc_count" => 1 }, { "key" => 15.0, "doc_count" => 2 }], shifted
    assert_equal [-20.0, -10.0], histogram(interval: 10, hard_bounds: { max: -10 }).fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal [0.0, 10.0, 20.0], histogram(interval: 10, hard_bounds: { min: 0 }).fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_empty histogram(interval: 10, hard_bounds: { min: 50 }).fetch("buckets")
    assert_equal histogram(interval: 10), histogram(interval: 10, hard_bounds: {}, extended_bounds: {})
  end

  def test_histogram_bounds_validate_types_endpoints_and_combined_limits
    [:extended_bounds, :hard_bounds].each do |kind|
      [nil, 1, { min: 2, max: 1 }, { min: Float::INFINITY }, { max: Float::NAN }, { other: 0 }, { min: "invalid" }].each do |bounds|
        assert_raises(ArgumentError) { histogram(interval: 10, kind => bounds) }
      end
    end
    [{ min: -10, max: 10 }, { min: 0, max: 30 }].each do |bounds|
      error = assert_raises(ArgumentError) { histogram(interval: 10, min_doc_count: 1, extended_bounds: bounds, hard_bounds: { min: 0, max: 20 }) }
      assert_includes error.message, "Extended bounds must be within hard bounds"
    end
    assert_equal histogram(interval: 10, hard_bounds: { min: -10, max: 20 }),
      histogram(interval: 10, hard_bounds: { min: -10, max: 20 }, extended_bounds: { min: 0, max: 10 })
  end

  private

  def histogram(**options)
    Tinkick::Aggregations.new(HistogramValue, @scope).call(prices: { histogram: { field: :price }.merge(options) }).fetch("prices")
  end
end
