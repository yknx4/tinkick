# frozen_string_literal: true

require_relative "../integration_helper"

class IanaFixedValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class IanaFixedHistogramsTest < TinkickIntegrationTest
  # Compare historical and DST inputs directly with PostgreSQL date_bin.
  CASES = [
    [:new_york_gap, "2h", "America/New_York", "2026-03-08T07:10:00Z"],
    [:new_york_first, "90m", "America/New_York", "2026-11-01T05:10:00Z"],
    [:new_york_second, "90m", "America/New_York", "2026-11-01T06:10:00Z"],
    [:lord_howe_gap, "45m", "Australia/Lord_Howe", "2026-10-03T15:35:00Z"],
    [:lord_howe_fold, "45m", "Australia/Lord_Howe", "2026-04-04T15:15:00Z"],
    [:kathmandu_gap, "90m", "Asia/Kathmandu", "1985-12-31T18:35:00Z"],
    [:samoa_skip, "36h", "Pacific/Apia", "2011-12-30T10:05:00Z"],
    [:athens_gap, "20m", "Europe/Athens", "1916-07-27T22:26:08Z"],
    [:athens_before_gap, "90m", "Europe/Athens", "1916-07-27T22:26:08Z"],
    [:singapore_fold, "90m", "Asia/Singapore", "1945-09-11T15:15:00Z"],
    [:pre_epoch_milliseconds, "333ms", "America/New_York", "1969-12-31T23:59:59.999Z"],
    [:interval_spanning_multiple_transitions, "400d", "America/New_York", "2026-11-01T06:10:00Z"],
  ].freeze

  CASES.each do |name, interval, zone, input|
    define_method("test_#{name}") do
      record = create_value(Time.iso8601(input), 1)
      expected = IanaFixedValue.where(id: record.id).pick(Arel.sql(
        "(EXTRACT(EPOCH FROM date_bin(?::interval, recorded_at AT TIME ZONE 'UTC', TIMESTAMP '1970-01-01' AT TIME ZONE ?)) * 1000)::bigint", interval, zone))
      buckets = search(fixed_interval: interval, time_zone: zone, min_doc_count: 1)

      assert_equal [expected], buckets.map { |bucket| bucket.fetch("key") }
      assert_equal [1], buckets.map { |bucket| bucket.fetch("doc_count") }
    end
  end

  def test_historical_amsterdam_uses_postgresql_offsets_for_keys_and_labels
    create_value(Time.utc(1937, 6, 30, 22, 40, 30), 1)

    assert_equal [{ "key" => -1_025_745_600_000, "key_as_string" => "1937-06-30T23:59:32.000+01:19", "doc_count" => 1 }],
      search(fixed_interval: "1m", time_zone: "Europe/Amsterdam", min_doc_count: 1)
  end

  def test_empty_buckets_use_elapsed_steps_without_loading_records
    [Time.utc(2026, 11, 1, 5, 10), Time.utc(2026, 11, 1, 8, 10)].each_with_index { |instant, index| create_value(instant, index) }
    instantiated = []
    buckets = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      buckets = search(fixed_interval: "90m", time_zone: "America/New_York", keyed: true)
    end

    assert_equal ["2026-11-01T01:00:00.000-04:00", "2026-11-01T01:30:00.000-05:00", "2026-11-01T03:00:00.000-05:00"], buckets.keys
    assert_equal [1, 0, 1], buckets.values.map { |bucket| bucket.fetch("doc_count") }
    assert_empty instantiated
  end

  def test_forward_gap_keeps_a_fixed_elapsed_interval
    [Time.utc(2026, 3, 8, 5, 10), Time.utc(2026, 3, 8, 9, 10)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(fixed_interval: "2h", time_zone: "America/New_York")

    assert_equal [5, 7, 9].map { |hour| Time.utc(2026, 3, 8, hour).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_offset_format_count_order_and_minimum_apply_to_rounded_keys
    [Time.utc(2026, 11, 1, 5, 40), Time.utc(2026, 11, 1, 7, 10), Time.utc(2026, 11, 1, 7, 15)]
      .each_with_index { |instant, index| create_value(instant, index) }
    options = { fixed_interval: "90m", time_zone: "America/New_York", offset: "30m", order: { _count: :desc }, min_doc_count: 1 }
    buckets = search(**options)

    assert_equal ["2026-11-01T02:00:00.000-05:00", "2026-11-01T01:30:00.000-04:00"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [2, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal [buckets.first], search(**options.merge(min_doc_count: 2))
  end

  def test_date_arrays_deduplicate_documents_and_ignore_null_or_empty_values
    first = Time.utc(2026, 11, 1, 5, 10)
    second = Time.utc(2026, 11, 1, 6, 40)
    create_value(first, 1, recorded_times: [first, first, second])
    create_value(first, 2, recorded_times: [nil, second])
    create_value(first, 3, recorded_times: [])
    create_value(first, 4)
    buckets = search(field: :recorded_times, fixed_interval: "90m", time_zone: "America/New_York", min_doc_count: 1)

    assert_equal [Time.utc(2026, 11, 1, 5), Time.utc(2026, 11, 1, 6, 30)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_extended_bounds_fill_an_empty_result_but_one_endpoint_cannot_define_a_range
    options = { fixed_interval: "90m", time_zone: "America/New_York" }
    assert_empty search(**options)
    assert_empty search(**options, extended_bounds: { min: "2026-11-01T00:10:00-04:00" })
    buckets = search(**options, extended_bounds: { min: "2026-11-01T00:10:00-04:00", max: "2026-11-01T03:10:00-05:00" })

    assert_equal [Time.utc(2026, 11, 1, 3, 30), Time.utc(2026, 11, 1, 5), Time.utc(2026, 11, 1, 6, 30), Time.utc(2026, 11, 1, 8)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_empty search(**options, min_doc_count: 1, extended_bounds: { min: "2026-11-01T00:10:00-04:00", max: "2026-11-01T03:10:00-05:00" })
  end

  def test_extended_bounds_expand_without_filtering_and_support_numeric_epoch_bounds
    create_value(Time.utc(2026, 11, 1, 8, 10), 1)
    buckets = search(fixed_interval: "90m", time_zone: "America/New_York", order: { _key: :desc },
      extended_bounds: { min: Time.utc(2026, 11, 1, 5, 40).to_i * 1_000, max: Time.utc(2026, 11, 1, 6, 40).to_i * 1_000 })

    assert_equal [Time.utc(2026, 11, 1, 8), Time.utc(2026, 11, 1, 6, 30), Time.utc(2026, 11, 1, 5)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_hard_bounds_check_shifted_keys_and_validate_extended_bounds
    [Time.utc(2026, 11, 1, 5, 40), Time.utc(2026, 11, 1, 6, 10), Time.utc(2026, 11, 1, 7, 10), Time.utc(2026, 11, 1, 8, 40)]
      .each_with_index { |instant, index| create_value(instant, index) }
    options = { fixed_interval: "90m", time_zone: "America/New_York", offset: "30m",
                hard_bounds: { min: "2026-11-01T01:40:00-04:00", max: "2026-11-01T03:10:00-05:00" } }
    buckets = search(**options)

    assert_equal [Time.utc(2026, 11, 1, 5, 30), Time.utc(2026, 11, 1, 7)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [2, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    error = assert_raises(ArgumentError) { search(**options, extended_bounds: { min: "2026-11-01T00:00:00-04:00" }) }
    assert_match(/Extended bounds must be within hard bounds/, error.message)
  end

  private

  def create_value(instant, index, **attributes)
    IanaFixedValue.create!(name: "Fixed observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index, **attributes)
  end

  def search(**options)
    Tinkick::Relation.new(IanaFixedValue, "observation", fields: [:name], misspellings: false,
      aggs: { events: { date_histogram: { field: :recorded_at }.merge(options) } }).aggs.fetch("events").fetch("buckets")
  end
end
