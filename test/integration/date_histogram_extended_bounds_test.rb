# frozen_string_literal: true

require_relative "../integration_helper"

class DateHistogramBoundsValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class DateHistogramExtendedBoundsTest < TinkickIntegrationTest
  def test_empty_matching_input_emits_inclusive_fixed_buckets_with_public_keyed_order
    create_value(Time.at(2).utc, 1, name: "Unrelated archive")
    buckets = search(fixed_interval: "250ms", extended_bounds: { min: -1, max: 501 },
      format: "epoch_millis", keyed: true, order: { _key: :desc }).aggs.fetch("events").fetch("buckets")

    assert_equal ["500", "250", "0", "-250"], buckets.keys
    assert_equal [500, 250, 0, -250], buckets.values.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 0, 0, 0], buckets.values.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_empty_input_with_only_one_endpoint_has_no_extent
    [{}, { min: 0 }, { max: 2_000 }, { min: nil, max: nil }].each do |bounds|
      assert_empty search(fixed_interval: "1s", extended_bounds: bounds).aggs.fetch("events").fetch("buckets"), bounds.inspect
    end
  end

  def test_one_sided_bounds_extend_the_matching_data_in_the_requested_direction
    [2, 4].each { |day| create_value(Time.utc(2026, 1, day), day) }
    lower = search(calendar_interval: :day, extended_bounds: { min: "2026-01-01" }).aggs.fetch("events").fetch("buckets")
    upper = search(calendar_interval: :day, extended_bounds: { max: "2026-01-05" }).aggs.fetch("events").fetch("buckets")

    assert_equal (1..4).map { |day| Time.utc(2026, 1, day).to_i * 1_000 }, lower.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 1, 0, 1], lower.map { |bucket| bucket.fetch("doc_count") }
    assert_equal (2..5).map { |day| Time.utc(2026, 1, day).to_i * 1_000 }, upper.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 1, 0], upper.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_bounds_do_not_filter_matching_documents_or_apply_the_search_page_limit
    [1, 3, 5].each { |day| create_value(Time.utc(2026, 1, day), day) }
    relation = search(calendar_interval: :day, extended_bounds: { min: "2026-01-02", max: "2026-01-04" })
    instantiated = []
    buckets = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      buckets = relation.aggs.fetch("events").fetch("buckets")
    end

    assert_equal (1..5).map { |day| Time.utc(2026, 1, day).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_empty instantiated
  end

  def test_positive_minimum_does_not_generate_extended_empty_buckets
    [2, 2, 4].each_with_index { |day, index| create_value(Time.utc(2026, 1, day), index) }
    options = { calendar_interval: :day, extended_bounds: { min: "2026-01-01", max: "2026-01-05" }, min_doc_count: 2 }
    buckets = search(**options).aggs.fetch("events").fetch("buckets")

    assert_equal [{ "key" => Time.utc(2026, 1, 2).to_i * 1_000, "key_as_string" => "2026-01-02T00:00:00.000Z", "doc_count" => 2 }], buckets
    assert_empty search(term: "absent", **options).aggs.fetch("events").fetch("buckets")
  end

  def test_numeric_bounds_are_epoch_milliseconds_while_string_bounds_use_the_format
    [2026, 2026.0].each do |value|
      buckets = search(calendar_interval: :year, extended_bounds: { min: value, max: value }).aggs.fetch("events").fetch("buckets")
      assert_equal [{ "key" => 0, "key_as_string" => "1970-01-01T00:00:00.000Z", "doc_count" => 0 }], buckets
    end
    string = search(calendar_interval: :year, extended_bounds: { min: "2026", max: "2026" }).aggs.fetch("events").fetch("buckets")
    assert_equal [Time.utc(2026).to_i * 1_000], string.map { |bucket| bucket.fetch("key") }
    custom = search(calendar_interval: :year, format: "yyyy/MM/dd", extended_bounds: { min: 2026, max: 2026 }).aggs.fetch("events").fetch("buckets")
    assert_equal ["1970/01/01"], custom.map { |bucket| bucket.fetch("key_as_string") }
  end

  def test_formatted_bounds_apply_date_math_and_the_configured_timezone
    buckets = search(calendar_interval: :month, time_zone: "+01:30", format: "yyyy/MM/dd||epoch_millis",
      extended_bounds: { min: "2026/01/02||/M", max: "2026/02/02||+1M/M" }).aggs.fetch("events").fetch("buckets")

    assert_equal [1, 2, 3].map { |month| Time.utc(2026, month).to_i * 1_000 - 5_400_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["2026/01/01", "2026/02/01", "2026/03/01"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_iana_bounds_round_without_the_offset_and_keep_the_dst_calendar_grid
    buckets = search(calendar_interval: :day, time_zone: "America/New_York", offset: "+6h",
      extended_bounds: { min: "2026-03-07T05:30:00Z", max: "2026-03-09T04:30:00Z" }).aggs.fetch("events").fetch("buckets")

    assert_equal [Time.utc(2026, 3, 7, 11), Time.utc(2026, 3, 8, 11), Time.utc(2026, 3, 9, 10)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["2026-03-07T06:00:00.000-05:00", "2026-03-08T07:00:00.000-04:00", "2026-03-09T06:00:00.000-04:00"],
      buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_fixed_timezone_bounds_round_before_the_bucket_offset
    buckets = search(fixed_interval: "1h", time_zone: "+01:30", offset: "+20m",
      extended_bounds: { min: 0, max: 7_200_000 }).aggs.fetch("events").fetch("buckets")

    assert_equal [-600_000, 3_000_000, 6_600_000], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["1970-01-01T01:20:00.000+01:30", "1970-01-01T02:20:00.000+01:30", "1970-01-01T03:20:00.000+01:30"],
      buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_samoa_skipped_date_does_not_duplicate_empty_extended_buckets
    buckets = search(calendar_interval: :day, time_zone: "Pacific/Apia",
      extended_bounds: { min: "2011-12-29", max: "2011-12-31" }).aggs.fetch("events").fetch("buckets")

    assert_equal [Time.utc(2011, 12, 29, 10), Time.utc(2011, 12, 30, 10)].map { |instant| instant.to_i * 1_000 },
      buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["2011-12-29T00:00:00.000-10:00", "2011-12-31T00:00:00.000+14:00"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_bounds_validate_shape_numeric_precision_and_order_before_rounding
    [nil, [], { lower: 0 }, { min: false }, { min: "invalid" }, { min: 2026.9 }, { min: Float::INFINITY },
      { max: Float::NAN }, { min: 2**63 }, { min: -(2**63) - 1 }, { min: 2, max: 1 },
      { min: "2026-01-02T01:00:00Z", max: "2026-01-02T00:00:00Z" }].each do |bounds|
      error = assert_raises(ArgumentError) { search(calendar_interval: :day, extended_bounds: bounds).aggs }
      assert_match(/bound/i, error.message, bounds.inspect)
    end
  end

  private

  def create_value(instant, index, name: "Bounded observation")
    DateHistogramBoundsValue.create!(name: name, code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index)
  end

  def search(term: "observation", **options)
    Tinkick::Relation.new(DateHistogramBoundsValue, term, fields: [:name], misspellings: false, limit: 1,
      aggs: { events: { date_histogram: { field: :recorded_at }.merge(options) } })
  end
end
