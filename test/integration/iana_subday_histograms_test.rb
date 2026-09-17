# frozen_string_literal: true

require_relative "../integration_helper"

class IanaSubdayValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class IanaSubdayHistogramsTest < TinkickIntegrationTest
  # Expected UTC keys were checked against Elasticsearch 8.19's actual prepared
  # Rounding implementation. Amsterdam below separately pins PostgreSQL's more
  # detailed historical timezone data, which differs from the installed JVM.
  CASES = [
    [:new_york_first_hour, :hour, "America/New_York", "2026-11-01T05:30:00Z", "2026-11-01T05:00:00Z"],
    [:new_york_second_hour, :hour, "America/New_York", "2026-11-01T06:30:00Z", "2026-11-01T06:00:00Z"],
    [:new_york_spring_hour, :hour, "America/New_York", "2026-03-08T07:30:00Z", "2026-03-08T07:00:00Z"],
    [:lord_howe_fall_hour, :hour, "Australia/Lord_Howe", "2026-04-04T15:15:00Z", "2026-04-04T14:00:00Z"],
    [:lord_howe_spring_hour, :hour, "Australia/Lord_Howe", "2026-10-03T15:45:00Z", "2026-10-03T14:30:00Z"],
    [:havana_first_hour, :hour, "America/Havana", "2026-11-01T04:30:00Z", "2026-11-01T04:00:00Z"],
    [:havana_second_hour, :hour, "America/Havana", "2026-11-01T05:30:00Z", "2026-11-01T05:00:00Z"],
    [:havana_gap_hour, :hour, "America/Havana", "2026-03-08T05:30:00Z", "2026-03-08T05:00:00Z"],
    [:moncton_historic_hour, :hour, "America/Moncton", "2003-10-26T03:43:35.079Z", "2003-10-26T03:00:00Z"],
    [:chatham_fall_hour, :hour, "Pacific/Chatham", "2015-04-04T14:15:00Z", "2015-04-04T14:15:00Z"],
    [:kathmandu_historic_hour, :hour, "Asia/Kathmandu", "1985-12-31T18:35:00Z", "1985-12-31T17:30:00Z"],
    [:singapore_historic_hour, :hour, "Asia/Singapore", "1945-09-11T15:15:00Z", "1945-09-11T14:30:00Z"],
    [:casey_historic_hour, :hour, "Antarctica/Casey", "2010-03-04T15:30:00Z", "2010-03-04T15:00:00Z"],
    [:athens_historic_hour, :hour, "Europe/Athens", "1916-07-27T22:26:08Z", "1916-07-27T22:25:08Z"],
    [:amsterdam_historic_second, :second, "Europe/Amsterdam", "1937-06-30T22:40:30.123Z", "1937-06-30T22:40:30Z"],
  ].freeze

  CASES.each do |name, unit, zone, input, expected|
    define_method("test_#{name}") do
      create_value(Time.iso8601(input), 1)
      buckets = search(calendar_interval: unit, time_zone: zone, min_doc_count: 1)

      assert_equal [Time.iso8601(expected).to_i * 1_000], buckets.map { |bucket| bucket.fetch("key") }
      assert_equal [1], buckets.map { |bucket| bucket.fetch("doc_count") }
    end
  end

  def test_historical_amsterdam_uses_postgresql_offsets_for_keys_and_labels
    create_value(Time.utc(1937, 6, 30, 22, 40, 30), 1)
    buckets = search(calendar_interval: :minute, time_zone: "Europe/Amsterdam", min_doc_count: 1)

    assert_equal [{ "key" => Time.utc(1937, 6, 30, 22, 39, 28).to_i * 1_000,
                    "key_as_string" => "1937-06-30T23:59:00.000+01:19", "doc_count" => 1 }], buckets
  end

  def test_empty_hour_buckets_preserve_both_occurrences_of_a_repeated_hour
    [Time.utc(2026, 11, 1, 4, 30), Time.utc(2026, 11, 1, 7, 30)].each_with_index { |instant, index| create_value(instant, index) }
    instantiated = []
    buckets = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      buckets = search(calendar_interval: :hour, time_zone: "America/New_York", keyed: true)
    end

    assert_equal ["2026-11-01T00:00:00.000-04:00", "2026-11-01T01:00:00.000-04:00",
      "2026-11-01T01:00:00.000-05:00", "2026-11-01T02:00:00.000-05:00"], buckets.keys
    assert_equal [1, 0, 0, 1], buckets.values.map { |bucket| bucket.fetch("doc_count") }
    assert_empty instantiated
  end

  def test_lord_howe_empty_hours_follow_the_changed_grid
    [Time.utc(2026, 4, 4, 14, 45), Time.utc(2026, 4, 4, 17, 45)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :hour, time_zone: "Australia/Lord_Howe")

    assert_equal [Time.utc(2026, 4, 4, 14), Time.utc(2026, 4, 4, 15, 30), Time.utc(2026, 4, 4, 16, 30), Time.utc(2026, 4, 4, 17, 30)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_offset_order_format_and_minimum_count_apply_after_utc_rounding
    [Time.utc(2026, 11, 1, 5, 45), Time.utc(2026, 11, 1, 6, 45), Time.utc(2026, 11, 1, 6, 50)]
      .each_with_index { |instant, index| create_value(instant, index) }
    options = { calendar_interval: :hour, time_zone: "America/New_York", offset: "30m", format: "yyyy/MM/dd HH:mm XXX", order: { _key: :desc }, min_doc_count: 1 }
    buckets = search(**options)

    assert_equal ["2026/11/01 01:30 -05:00", "2026/11/01 01:30 -04:00"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [2, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal [buckets.first], search(**options.merge(min_doc_count: 2))
  end

  def test_date_arrays_count_each_record_once_per_repeated_hour
    first = Time.utc(2026, 11, 1, 5, 30)
    second = Time.utc(2026, 11, 1, 6, 30)
    create_value(first, 1, recorded_times: [first, first, second])
    create_value(first, 2, recorded_times: [nil, second])
    create_value(first, 3, recorded_times: [])
    buckets = search(field: :recorded_times, calendar_interval: :hour, time_zone: "America/New_York")

    assert_equal [Time.utc(2026, 11, 1, 5), Time.utc(2026, 11, 1, 6)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_extended_bounds_fill_both_repeated_hours_without_matching_rows
    buckets = search(calendar_interval: :hour, time_zone: "America/New_York", extended_bounds: {
      min: "2026-11-01T00:30:00-04:00", max: "2026-11-01T02:30:00-05:00",
    })

    assert_equal (4..7).map { |hour| Time.utc(2026, 11, 1, hour).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_hard_bounds_apply_to_shifted_utc_keys_with_repeated_hours
    (5..8).each { |hour| create_value(Time.utc(2026, 11, 1, hour, 45), hour) }
    buckets = search(calendar_interval: :hour, time_zone: "America/New_York", offset: "30m", hard_bounds: {
      min: Time.utc(2026, 11, 1, 6, 30).to_i * 1_000, max: Time.utc(2026, 11, 1, 8, 30).to_i * 1_000,
    })

    assert_equal [Time.utc(2026, 11, 1, 6, 30), Time.utc(2026, 11, 1, 7, 30)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  private

  def create_value(instant, index, **attributes)
    IanaSubdayValue.create!(name: "Subday observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index, **attributes)
  end

  def search(**options)
    Tinkick::Relation.new(IanaSubdayValue, "observation", fields: [:name], misspellings: false,
      aggs: { events: { date_histogram: { field: :recorded_at }.merge(options) } }).aggs.fetch("events").fetch("buckets")
  end
end
