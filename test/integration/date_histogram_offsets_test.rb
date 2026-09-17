# frozen_string_literal: true

require_relative "../integration_helper"

class DateHistogramOffsetValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class DateHistogramOffsetsTest < TinkickIntegrationTest
  def test_day_offset_changes_membership_and_fills_shifted_empty_buckets
    [Time.utc(2026, 1, 2, 5, 59, 59.999), Time.utc(2026, 1, 2, 6), Time.utc(2026, 1, 5, 5)]
      .each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :day, offset: "+6h").aggs.fetch("events").fetch("buckets")

    assert_equal (1..4).map { |day| Time.utc(2026, 1, day, 6).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal "2026-01-01T06:00:00.000Z", buckets.first.fetch("key_as_string")
  end

  def test_negative_offsets_and_numeric_milliseconds_use_the_same_grid
    create_value(Time.utc(2026, 1, 2, 5), 1)
    expected = [{ "key" => Time.utc(2026, 1, 1, 18).to_i * 1_000, "key_as_string" => "2026-01-01T18:00:00.000Z", "doc_count" => 1 }]
    ["-6h", -21_600_000, -21_600_000.9].each do |offset|
      assert_equal expected, search(calendar_interval: :day, offset: offset).aggs.fetch("events").fetch("buckets")
    end
  end

  def test_fixed_subsecond_offsets_preserve_pre_epoch_and_exact_boundaries
    [-1, 249, 250, 2_250].each_with_index { |milliseconds, index| create_value(Time.at(Rational(milliseconds, 1_000)).utc, index) }
    buckets = search(fixed_interval: "1s", offset: 250.9, format: "epoch_millis", keyed: true).aggs.fetch("events").fetch("buckets")

    assert_equal ["-750", "250", "1250", "2250"], buckets.keys
    assert_equal [2, 1, 0, 1], buckets.values.map { |bucket| bucket.fetch("doc_count") }
    assert_equal [-750, 250, 1_250, 2_250], buckets.values.map { |bucket| bucket.fetch("key") }
  end

  def test_fixed_interval_offset_combines_with_the_fixed_timezone
    [Time.at(0).utc, Time.at(5_400).utc].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(fixed_interval: "90m", offset: "20m", time_zone: "+01:30").aggs.fetch("events").fetch("buckets")

    assert_equal [-4_200_000, 1_200_000], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["1970-01-01T00:20:00.000+01:30", "1970-01-01T01:50:00.000+01:30"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_iana_offset_wraps_utc_rounding_across_dst_instead_of_adding_wall_hours
    (7..9).each { |day| create_value(Time.utc(2026, 3, day, 12), day) }
    buckets = search(calendar_interval: :day, offset: "+6h", time_zone: "America/New_York").aggs.fetch("events").fetch("buckets")

    assert_equal [Time.utc(2026, 3, 7, 11), Time.utc(2026, 3, 8, 11), Time.utc(2026, 3, 9, 10)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["2026-03-07T06:00:00.000-05:00", "2026-03-08T07:00:00.000-04:00", "2026-03-09T06:00:00.000-04:00"],
      buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 1, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_long_month_offset_keeps_elapsed_days_and_the_unshifted_calendar_series
    [Time.utc(2024, 1, 15), Time.utc(2024, 2, 15), Time.utc(2024, 4, 15)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :month, offset: "+40d").aggs.fetch("events").fetch("buckets")

    assert_equal ["2024-01-10T00:00:00.000Z", "2024-02-10T00:00:00.000Z", "2024-03-12T00:00:00.000Z", "2024-04-10T00:00:00.000Z"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_zero_and_submillisecond_offsets_match_the_default
    create_value(Time.at(Rational(1_234, 1_000)).utc, 1)
    expected = search(fixed_interval: "1s").aggs
    [0.9, -0.9, "0", "-0ms", "-999micros", "+999999nanos"].each do |offset|
      assert_equal expected, search(fixed_interval: "1s", offset: offset).aggs, offset.inspect
    end
  end

  def test_offset_rejects_invalid_types_nonfinite_values_and_out_of_range_quantities
    [nil, true, {}, "", "1.5h", "1M", "1w", "1s); SELECT 1", "9223372036854775808ms", 2**63, -(2**63) - 1, Float::INFINITY, Float::NAN].each do |offset|
      error = assert_raises(ArgumentError) { search(calendar_interval: :day, offset: offset).aggs }
      assert_match(/offset/, error.message)
    end
  end

  private

  def create_value(instant, index)
    DateHistogramOffsetValue.create!(name: "Shifted observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index)
  end

  def search(**options)
    Tinkick::Relation.new(DateHistogramOffsetValue, "observation", fields: [:name], misspellings: false,
      aggs: { events: { date_histogram: { field: :recorded_at }.merge(options) } })
  end
end
