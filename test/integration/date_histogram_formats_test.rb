# frozen_string_literal: true

require_relative "../integration_helper"

class DateHistogramFormatValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class DateHistogramFormatsTest < TinkickIntegrationTest
  def test_public_month_format_changes_labels_without_changing_keys_or_counts
    [Time.utc(2026, 1, 15), Time.utc(2026, 3, 15), Time.utc(2026, 3, 16)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :month, format: "strict_date_optional_time").aggs.fetch("events").fetch("buckets")

    assert_equal ["2026-01-01T00:00:00.000Z", "2026-02-01T00:00:00.000Z", "2026-03-01T00:00:00.000Z"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 2, 3].map { |month| Time.utc(2026, month).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_fixed_interval_format_uses_the_requested_offset_clock
    [Time.utc(1970, 1, 1, 0, 45), Time.utc(1970, 1, 1, 2, 15)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(fixed_interval: "1h", time_zone: "+01:30").aggs.fetch("events").fetch("buckets")

    assert_equal ["1970-01-01T02:00:00.000+01:30", "1970-01-01T03:00:00.000+01:30"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1_800_000, 5_400_000], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_iana_gap_and_keyed_format_use_the_resolved_first_valid_boundary
    [Time.utc(2026, 3, 7, 12), Time.utc(2026, 3, 8, 5, 30)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :day, time_zone: "America/Havana", keyed: true)
      .aggs.fetch("events").fetch("buckets")

    assert_equal ["2026-03-07T00:00:00.000-05:00", "2026-03-08T01:00:00.000-04:00"], buckets.keys
    assert_equal buckets.keys, buckets.values.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [Time.utc(2026, 3, 7, 5), Time.utc(2026, 3, 8, 5)].map { |instant| instant.to_i * 1_000 },
      buckets.values.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 1], buckets.values.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_epoch_millis_keys_stay_utc_when_the_calendar_uses_an_iana_zone
    [Time.utc(2026, 3, 8, 12), Time.utc(2026, 3, 9, 12)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :day, time_zone: "America/New_York", format: "epoch_millis", keyed: true)
      .aggs.fetch("events").fetch("buckets")
    expected = [Time.utc(2026, 3, 8, 5), Time.utc(2026, 3, 9, 4)].map { |instant| instant.to_i * 1_000 }

    assert_equal expected.map(&:to_s), buckets.keys
    assert_equal expected, buckets.values.map { |bucket| bucket.fetch("key") }
    assert_equal buckets.keys, buckets.values.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 1], buckets.values.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_format_requires_an_inner_string_and_valid_supported_pattern
    ["", nil, false, 123, {}].each do |format|
      error = assert_raises(ArgumentError) { search(calendar_interval: :day, format: format).aggs }
      assert_match(/format|token|quote/, error.message)
    end
    error = assert_raises(ArgumentError) do
      Tinkick::Relation.new(DateHistogramFormatValue, "observation", fields: [:name], misspellings: false,
        aggs: { events: { date_histogram: { field: :recorded_at, calendar_interval: :day }, format: "yyyy/MM/dd" } }).aggs
    end
    assert_includes error.message, "inside date_histogram"
  end

  def test_java_patterns_and_format_lists_raise_with_native_guidance
    ["yyyy/MM/dd", "yyyy 'unfinished", "epoch_millis||strict_date_optional_time"].each do |format|
      error = assert_raises(Tinkick::NotImplementedError) { search(calendar_interval: :day, format: format).aggs }
      assert_match(/application.*to_char/, error.message)
    end
  end

  private


  def create_value(instant, index)
    DateHistogramFormatValue.create!(name: "Formatted observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index)
  end

  def search(**options)
    Tinkick::Relation.new(DateHistogramFormatValue, "observation", fields: [:name], misspellings: false,
      aggs: { events: { date_histogram: { field: :recorded_at }.merge(options) } })
  end
end
