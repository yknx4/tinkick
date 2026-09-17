# frozen_string_literal: true

require_relative "../integration_helper"

class AggregationMissingTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
    default_scope { where.not(name: "hidden voyage") }
  end

  setup do
    SearchProduct.delete_all
    @records = [
      [nil, nil, nil],
      [nil, [], []],
      ["", [nil, nil], [nil, nil]],
      ["Known", ["Known", nil, "Known"], [2, nil, 2]],
      ["Unknown", ["Unknown"], [6]],
    ].each_with_index.map do |(description, tags, ratings), index|
      SearchProduct.create!(name: "voyage entry #{index}", description: description, tags: tags, ratings: ratings)
    end
    SearchProduct.create!(name: "archive entry", description: "Archive", tags: ["Archive"], ratings: [100])
    SearchProduct.create!(name: "hidden voyage", description: "Hidden", tags: ["Hidden"], ratings: [1_000])
  end

  def test_scalar_terms_replace_null_but_preserve_empty_strings_and_existing_values
    page = search(description: { missing: "Unknown" })

    assert_equal({ "Unknown" => 3, "" => 1, "Known" => 1 }, buckets(page, :description))
    assert_equal 5, page.total_count
    assert_equal @records.map(&:id).sort, page.map(&:id).sort
  end

  def test_array_terms_emit_one_fallback_per_missing_document
    page = search(tags: { missing: "Unknown" })

    assert_equal({ "Unknown" => 4, "Known" => 1 }, buckets(page, :tags))
    limited = search(tags: { missing: "Unknown", limit: 1 }).aggs.fetch("tags")
    assert_equal [{ "key" => "Unknown", "doc_count" => 4 }], limited.fetch("buckets")
    assert_equal 1, limited.fetch("sum_other_doc_count")
  end

  def test_zero_count_dictionary_keeps_fallback_and_model_scope
    page = search(tags: { missing: "Unknown", min_doc_count: 0 })

    assert_equal({ "Unknown" => 4, "Known" => 1, "Archive" => 0 }, buckets(page, :tags))
  end

  def test_terms_include_and_exclude_filter_the_replacement_value
    page = search(tags: { missing: "Unknown", include: ["Unknown", "Known"], exclude: ["Known"] })

    assert_equal({ "Unknown" => 4 }, buckets(page, :tags))
    assert_equal 0, page.aggs.fetch("tags").fetch("sum_other_doc_count")
  end

  def test_symbol_fallback_uses_its_string_value
    page = search(description: { missing: :Unknown }, tags: { missing: :Unknown })

    assert_equal({ "Unknown" => 3, "" => 1, "Known" => 1 }, buckets(page, :description))
    assert_equal({ "Unknown" => 4, "Known" => 1 }, buckets(page, :tags))
  end

  def test_numeric_metrics_preserve_duplicates_and_replace_missing_arrays_once
    page = search(total: { sum: { field: :ratings, missing: 4 } },
      average: { avg: { field: :ratings, missing: 4 } },
      low: { min: { field: :ratings, missing: 4 } },
      high: { max: { field: :ratings, missing: 4 } },
      distinct: { cardinality: { field: :ratings, missing: 4 } })

    assert_equal 22.0, page.aggs.fetch("total").fetch("value")
    assert_in_delta 22.0 / 6, page.aggs.fetch("average").fetch("value"), 0.000001
    assert_equal 2.0, page.aggs.fetch("low").fetch("value")
    assert_equal 6.0, page.aggs.fetch("high").fetch("value")
    assert_equal 3, page.aggs.fetch("distinct").fetch("value")
  end

  def test_cardinality_coalesces_scalar_text_and_colliding_fallback_values
    page = search(description: { cardinality: { missing: "Unknown" } },
      tags: { cardinality: { missing: "Known" } })

    assert_equal 3, page.aggs.fetch("description").fetch("value")
    assert_equal 2, page.aggs.fetch("tags").fetch("value")
  end

  def test_zero_fallback_and_aggregation_filters_preserve_document_counts
    page = search(ratings: { sum: { missing: 0 }, where: { id: @records.first(3).map(&:id) } })

    assert_equal 0.0, page.aggs.fetch("ratings").fetch("value")
    assert_equal 3, page.aggs.fetch("ratings").fetch("doc_count")
    assert_equal 5, page.total_count
  end

  def test_empty_matching_scope_does_not_invent_a_fallback_document
    page = search(description: { missing: "Unknown", where: { id: -1 } },
      ratings: { sum: { missing: 4 }, where: { id: -1 } })

    assert_empty buckets(page, :description)
    assert_equal 0.0, page.aggs.fetch("ratings").fetch("value")
    assert_equal 0, page.aggs.fetch("ratings").fetch("doc_count")
  end

  def test_nil_fallback_does_not_change_ordinary_aggregation_results
    [:description, :tags].each do |field|
      assert_equal buckets(search(field => {}), field), buckets(search(field => { missing: nil }), field)
    end
  end

  def test_hostile_fallback_is_a_bound_literal_and_no_models_are_loaded
    fallback = %q[Unknown'); SELECT 1; --]
    page = search(description: { missing: fallback })
    instantiated = []
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      assert_equal 2, buckets(page, :description).fetch(fallback)
    end

    assert_empty instantiated
    assert_equal 5, page.total_count
  end

  def test_missing_field_and_invalid_native_numeric_cast_still_raise
    assert_raises(Tinkick::MissingFieldError) { search(absent: { missing: "Unknown" }).aggs }
    error = assert_raises(ActiveRecord::StatementInvalid) do
      SearchProduct.transaction(requires_new: true) { search(ratings: { sum: { missing: "invalid" } }).aggs }
    end
    assert_kind_of PG::InvalidTextRepresentation, error.cause
  end

  def test_unsupported_missing_placements_are_rejected
    [
      { ratings: { missing: 0, sum: {} } },
      { ratings: { missing: 0, histogram: { interval: 2 } } },
      { description: { missing: "2026-01-01", date_histogram: { calendar_interval: "day" } } },
    ].each do |options|
      assert_raises(ArgumentError, Tinkick::NotImplementedError) { search(**options).aggs }
    end
  end

  def test_numeric_range_defaults_count_missing_documents_once_in_each_matching_bucket
    result = search(ratings: { missing: 0, ranges: [
      { key: "low", from: 0, to: 4 }, { key: "high", from: 4 }, { key: "all", from: 0, to: 8 },
    ] }).aggs.fetch("ratings").fetch("buckets")

    assert_equal({ "low" => 4, "high" => 1, "all" => 5 }, result.to_h { |bucket| [bucket.fetch("key"), bucket.fetch("doc_count")] })
    assert_equal 5, search(ratings: { ranges: [{}], missing: 0 }).total_count
  end

  def test_numeric_range_defaults_keep_scope_filters_and_keyed_results
    result = search(ratings: { missing: 4, keyed: true,
      ranges: [{ key: "below", to: 4 }, { key: "fallback", from: 4, to: 5 }],
      where: { id: @records.first(3).map(&:id) } }).aggs.fetch("ratings")

    assert_equal 3, result.fetch("doc_count")
    assert_equal 0, result.fetch("buckets").fetch("below").fetch("doc_count")
    assert_equal 3, result.fetch("buckets").fetch("fallback").fetch("doc_count")
  end

  def test_numeric_histogram_defaults_share_buckets_with_existing_values
    page = search(ratings: { histogram: { interval: 4, missing: 4, min_doc_count: 1 } })

    assert_equal({ 0.0 => 1, 4.0 => 4 }, buckets(page, :ratings))
    assert_equal 5, page.total_count
    assert_equal @records.map(&:id).sort, page.map(&:id).sort
  end

  def test_numeric_histogram_zero_defaults_combine_with_offset_and_keyed_results
    result = search(ratings: { histogram: { interval: 4, offset: 1, missing: 0, min_doc_count: 1, keyed: true } })
      .aggs.fetch("ratings").fetch("buckets")

    assert_equal({ "-3.0" => 3, "1.0" => 1, "5.0" => 1 }, result.transform_values { |bucket| bucket.fetch("doc_count") })
  end

  def test_numeric_histogram_defaults_preserve_dense_bounds_and_aggregation_filters
    page = search(ratings: { histogram: { interval: 4, missing: 0,
      extended_bounds: { min: 0, max: 8 }, hard_bounds: { min: 0, max: 8 } },
      where: { id: @records.first(3).map(&:id) } })

    assert_equal({ 0.0 => 3, 4.0 => 0, 8.0 => 0 }, buckets(page, :ratings))
    assert_equal 3, page.aggs.fetch("ratings").fetch("doc_count")
  end

  def test_missing_defaults_do_not_invent_documents_for_empty_numeric_buckets
    result = search(ratings: { missing: 0, ranges: [{}], where: { id: -1 } }).aggs.fetch("ratings")
    assert_equal 0, result.fetch("buckets").first.fetch("doc_count")
    assert_empty buckets(search(ratings: { histogram: { interval: 4, missing: 0 }, where: { id: -1 } }), :ratings)

    [:ranges, :histogram].each do |kind|
      options = kind == :ranges ? { ranges: [{}], missing: nil } : { histogram: { interval: 4, missing: nil } }
      expected = kind == :ranges ? { ranges: [{}] } : { histogram: { interval: 4 } }
      assert_equal search(ratings: expected).aggs, search(ratings: options).aggs
    end
  end

  private

  def search(**aggregations)
    Product.search("voyage", aggs: aggregations, misspellings: false)
  end

  def buckets(page, field)
    page.aggs.fetch(field.to_s).fetch("buckets").to_h { |bucket| [bucket.fetch("key"), bucket.fetch("doc_count")] }
  end
end
