# frozen_string_literal: true

require_relative "../integration_helper"

class IanaCalendarValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class IanaCalendarHistogramsTest < TinkickIntegrationTest
  def test_new_york_days_fill_empty_buckets_across_23_and_25_hour_days
    [
      [Time.utc(2026, 3, 7, 12), Time.utc(2026, 3, 9, 12), [Time.utc(2026, 3, 7, 5), Time.utc(2026, 3, 8, 5), Time.utc(2026, 3, 9, 4)]],
      [Time.utc(2026, 10, 31, 12), Time.utc(2026, 11, 2, 12), [Time.utc(2026, 10, 31, 4), Time.utc(2026, 11, 1, 4), Time.utc(2026, 11, 2, 5)]],
    ].each do |first, last, expected|
      [first, last].each_with_index { |instant, index| create_value(instant, index) }
      search = Tinkick::Relation.new(IanaCalendarValue, "observation", fields: [:name], misspellings: false, smart_aggs: false,
        where: { recorded_at: { gte: first, lte: last } },
        aggs: { events: { date_histogram: { field: :recorded_at, calendar_interval: :day, time_zone: "America/New_York" } } })
      instantiated = []
      buckets = nil
      ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
        buckets = search.aggs.fetch("events").fetch("buckets")
      end

      assert_equal expected.map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
      assert_equal [1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
      assert_empty instantiated
    end
  end

  def test_repeated_havana_midnight_uses_postgresql_standard_time_resolution
    [Time.utc(2026, 11, 1, 4, 30), Time.utc(2026, 11, 1, 5, 30)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = histogram(time_zone: "America/Havana", min_doc_count: 2).fetch("buckets")

    assert_equal [{ "key" => Time.utc(2026, 11, 1, 5).to_i * 1_000, "key_as_string" => "2026-11-01T00:00:00.000-05:00", "doc_count" => 2 }], buckets
  end

  def test_missing_havana_midnight_uses_the_first_valid_instant
    create_value(Time.utc(2026, 3, 8, 5, 30), 1)
    buckets = histogram(time_zone: "America/Havana").fetch("buckets")

    assert_equal [{ "key" => Time.utc(2026, 3, 8, 5).to_i * 1_000, "key_as_string" => "2026-03-08T01:00:00.000-04:00", "doc_count" => 1 }], buckets
  end

  def test_larger_calendar_units_group_the_local_date_and_ignore_session_timezone
    create_value(Time.utc(2026, 1, 1, 2), 1) # Still December 31 in New York.
    IanaCalendarValue.with_connection { |connection| connection.execute("SET LOCAL TIME ZONE 'Asia/Tokyo'") }
    expected = {
      day: Time.utc(2025, 12, 31, 5), week: Time.utc(2025, 12, 29, 5), month: Time.utc(2025, 12, 1, 5),
      quarter: Time.utc(2025, 10, 1, 4), year: Time.utc(2025, 1, 1, 5),
    }
    expected.each do |unit, instant|
      bucket = histogram(calendar_interval: unit, time_zone: "America/New_York").fetch("buckets").first

      assert_equal instant.to_i * 1_000, bucket.fetch("key"), unit.to_s
      assert_equal 1, bucket.fetch("doc_count"), unit.to_s
    end
  end

  def test_samoa_skipped_date_has_no_duplicate_bucket_or_lost_counts
    [Time.utc(2011, 12, 29, 11), Time.utc(2011, 12, 30, 11), Time.utc(2011, 12, 30, 12), Time.utc(2012, 1, 1, 11)]
      .each_with_index { |instant, index| create_value(instant, index) }
    buckets = histogram(time_zone: "Pacific/Apia").fetch("buckets")

    assert_equal [Time.utc(2011, 12, 29, 10), Time.utc(2011, 12, 30, 10), Time.utc(2011, 12, 31, 10), Time.utc(2012, 1, 1, 10)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 2, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal ["2011-12-29", "2011-12-31", "2012-01-01", "2012-01-02"], buckets.map { |bucket| bucket.fetch("key_as_string")[0, 10] }
    ordered = histogram(time_zone: "Pacific/Apia", order: { _count: :asc }, keyed: true).fetch("buckets")
    assert_equal [0, 1, 1, 2], ordered.values.map { |bucket| bucket.fetch("doc_count") }
    assert_equal ["2012-01-01", "2011-12-29", "2012-01-02", "2011-12-31"], ordered.keys.map { |label| label[0, 10] }
    assert_equal [2], histogram(time_zone: "Pacific/Apia", min_doc_count: 2).fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
  end

  def test_lord_howe_calendar_days_span_the_half_hour_transition
    [Time.utc(2026, 10, 3, 12), Time.utc(2026, 10, 5, 12)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = histogram(time_zone: "Australia/Lord_Howe").fetch("buckets")

    assert_equal [Time.utc(2026, 10, 2, 13, 30), Time.utc(2026, 10, 3, 13, 30), Time.utc(2026, 10, 4, 13)]
      .map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  private

  def create_value(instant, index)
    IanaCalendarValue.create!(name: "Calendar observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index)
  end

  def histogram(**options)
    scope = IanaCalendarValue.where("name ==> ?", "observation")
    Tinkick::Aggregations.new(IanaCalendarValue, scope).call(events: {
      date_histogram: { field: :recorded_at, calendar_interval: :day }.merge(options),
    }).fetch("events")
  end
end
