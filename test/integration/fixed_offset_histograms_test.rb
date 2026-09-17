# frozen_string_literal: true

require_relative "../integration_helper"

class FixedOffsetHistogramValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class FixedOffsetHistogramsTest < TinkickIntegrationTest
  def test_public_calendar_days_reproduce_searchkicks_offset_example
    start = Time.utc(2018, 6, 19)
    [start, start + 16 * 3_600, start + 16 * 3_600].each_with_index { |instant, index| create_value(instant, index) }
    london = Tinkick::Relation.new(FixedOffsetHistogramValue, "observation", fields: [:name], misspellings: false,
      aggs: { events: { date_histogram: { field: :recorded_at, calendar_interval: :day, time_zone: "+01:00" } } })
    assert_equal [{ "key" => 1_529_362_800_000, "key_as_string" => "2018-06-19T00:00:00.000+01:00", "doc_count" => 3 }],
      london.aggs.fetch("events").fetch("buckets")
    assert_equal [
      { "key" => 1_529_330_400_000, "key_as_string" => "2018-06-19T00:00:00.000+10:00", "doc_count" => 1 },
      { "key" => 1_529_416_800_000, "key_as_string" => "2018-06-20T00:00:00.000+10:00", "doc_count" => 2 },
    ], histogram(calendar_interval: :day, time_zone: "+10:00").fetch("buckets")
  end

  def test_half_hour_negative_and_numeric_offsets_change_keys_and_keyed_labels
    create_value(Time.utc(2018, 6, 19, 0, 30), 1)
    positive = histogram(calendar_interval: :day, time_zone: "+01:30", keyed: true).fetch("buckets")
    negative = histogram(calendar_interval: :day, time_zone: "-05:00").fetch("buckets")

    assert_equal ["2018-06-19T00:00:00.000+01:30"], positive.keys
    assert_equal Time.utc(2018, 6, 18, 22, 30).to_i * 1_000, positive.values.first.fetch("key")
    assert_equal [{ "key" => Time.utc(2018, 6, 18, 5).to_i * 1_000, "key_as_string" => "2018-06-18T00:00:00.000-05:00", "doc_count" => 1 }], negative
    assert_equal negative, histogram(calendar_interval: :day, time_zone: -5).fetch("buckets")
    assert_equal histogram(calendar_interval: :day, time_zone: "+01:00"), histogram(calendar_interval: :day, time_zone: 1.9)
    assert_equal histogram(calendar_interval: :day), histogram(calendar_interval: :day, time_zone: "Z")
  end

  def test_fixed_intervals_use_the_offset_grid_and_preserve_pre_epoch_subseconds
    [-1, 3_501].each_with_index { |milliseconds, index| create_value(Time.at(Rational(milliseconds, 1_000)).utc, index) }
    FixedOffsetHistogramValue.with_connection { |connection| connection.execute("SET LOCAL TIME ZONE 'America/New_York'") }
    buckets = histogram(fixed_interval: "1500ms", time_zone: "+00:00:01").fetch("buckets")

    assert_equal [-1_000, 500, 2_000, 3_500], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    # ES's default label printer omits offset seconds, including an all-zero HH:MM suffix.
    assert_equal "1970-01-01T00:00:00.000Z", buckets.first.fetch("key_as_string")
    assert_equal "1970-01-01T00:00:04.500Z", buckets.last.fetch("key_as_string")
    assert_equal [-1_800_000], histogram(fixed_interval: "90m", time_zone: "+00:30", min_doc_count: 1)
      .fetch("buckets").map { |bucket| bucket.fetch("key") }
  end

  def test_offset_calendar_empty_buckets_advance_in_local_days
    [Time.utc(2026, 1, 1), Time.utc(2026, 1, 3)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = histogram(calendar_interval: :day, time_zone: "+01:30").fetch("buckets")

    assert_equal [Time.utc(2025, 12, 31, 22, 30), Time.utc(2026, 1, 1, 22, 30), Time.utc(2026, 1, 2, 22, 30)].map { |instant| instant.to_i * 1_000 },
      buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_offset_month_series_does_not_drift_after_february
    [Time.utc(2024, 1, 15), Time.utc(2024, 4, 15)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = histogram(calendar_interval: :month, time_zone: "+01:30").fetch("buckets")

    assert_equal [Time.utc(2023, 12, 31, 22, 30), Time.utc(2024, 1, 31, 22, 30), Time.utc(2024, 2, 29, 22, 30), Time.utc(2024, 3, 31, 22, 30)].map { |instant| instant.to_i * 1_000 },
      buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_public_date_ranges_accept_numeric_offset_hours
    [Time.utc(2026, 1, 1, 22, 30), Time.utc(2026, 1, 1, 23, 30), Time.utc(2026, 1, 2, 22, 30)].each_with_index do |instant, index|
      create_value(instant, index)
    end
    search = Tinkick::Relation.new(FixedOffsetHistogramValue, "observation", fields: [:name], misspellings: false,
      aggs: { events: { field: :recorded_at, time_zone: 1.9, date_ranges: [{ from: "2026-01-02", to: "2026-01-03" }] } })
    bucket = search.aggs.fetch("events").fetch("buckets").first

    assert_equal 2, bucket.fetch("doc_count")
    assert_equal Time.utc(2026, 1, 1, 23).to_i * 1_000, bucket.fetch("from")
    assert_equal "2026-01-02T00:00:00.000+01:00", bucket.fetch("from_as_string")
    assert_equal "2026-01-03T00:00:00.000+01:00", bucket.fetch("to_as_string")
  end

  private

  def create_value(instant, index)
    FixedOffsetHistogramValue.create!(name: "Offset observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index)
  end

  def histogram(**options)
    scope = FixedOffsetHistogramValue.where("name ==> ?", "observation")
    Tinkick::Aggregations.new(FixedOffsetHistogramValue, scope).call(events: { date_histogram: { field: :recorded_at }.merge(options) }).fetch("events")
  end
end
