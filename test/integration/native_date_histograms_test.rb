# frozen_string_literal: true

require_relative "../integration_helper"

class NativeHistogramValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class NativeDateHistogramsTest < TinkickIntegrationTest
  def test_calendar_rounding_uses_postgresql_timezone_rules_without_historical_corrections
    [
      ["Australia/Lord_Howe", "2026-04-04T15:15:00Z"],
      ["Asia/Kathmandu", "1985-12-31T18:35:00Z"],
      ["Europe/Athens", "1916-07-27T22:26:08Z"],
    ].each_with_index do |(zone, input), index|
      record = create_value(Time.iso8601(input), index)
      scope = NativeHistogramValue.where(id: record.id)
      expected = scope.pick(Arel.sql("(EXTRACT(EPOCH FROM date_trunc('hour', recorded_at AT TIME ZONE 'UTC', ?)) * 1000)::bigint", zone))
      buckets = histogram(scope, calendar_interval: :hour, time_zone: zone, min_doc_count: 1)

      assert_equal [expected], buckets.map { |bucket| bucket.fetch("key") }, zone
      assert_equal [1], buckets.map { |bucket| bucket.fetch("doc_count") }
    end
  end

  def test_fixed_intervals_remain_elapsed_time_across_daylight_saving_changes
    [Time.utc(2026, 3, 8, 5, 10), Time.utc(2026, 3, 8, 9, 10)].each_with_index { |instant, index| create_value(instant, index) }
    buckets = histogram(scope, fixed_interval: "2h", time_zone: "America/New_York")

    assert_equal [5, 7, 9].map { |hour| Time.utc(2026, 3, 8, hour).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [1, 0, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_fixed_timezone_changes_the_origin_without_reconstructing_transitions
    [Time.utc(2026, 11, 1, 5, 10), Time.utc(2026, 11, 1, 6, 10), Time.utc(2026, 11, 1, 8, 10)]
      .each_with_index { |instant, index| create_value(instant, index) }
    expected = scope.group(Arel.sql("date_bin(INTERVAL '90 minutes', recorded_at AT TIME ZONE 'UTC', TIMESTAMP '1970-01-01' AT TIME ZONE 'America/New_York')"))
      .count.transform_keys { |instant| instant.to_i * 1_000 }.sort
    statements = []
    buckets = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { statements << arguments.last.fetch(:sql) }, "sql.active_record") do
      buckets = histogram(scope, fixed_interval: "90m", time_zone: "America/New_York", min_doc_count: 1)
    end

    assert_equal expected, buckets.map { |bucket| bucket.values_at("key", "doc_count") }
    assert_includes statements.join, "date_bin"
    refute_match(/WITH RECURSIVE|before_offset|period_index|width_bucket/i, statements.join)
  end

  def test_empty_fixed_buckets_use_the_same_native_origin_and_elapsed_step
    buckets = histogram(scope, fixed_interval: "2h", time_zone: "America/New_York", extended_bounds: {
      min: "2026-03-08T05:10:00Z", max: "2026-03-08T09:10:00Z",
    })

    assert_equal [5, 7, 9].map { |hour| Time.utc(2026, 3, 8, hour).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  private

  def create_value(instant, index)
    NativeHistogramValue.create!(name: "Native date observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, price: index)
  end

  def scope
    NativeHistogramValue.where("name ==> ?", "observation")
  end

  def histogram(relation, **options)
    Tinkick::Aggregations.new(NativeHistogramValue, relation).call(events: {
      date_histogram: { field: :recorded_at }.merge(options),
    }).fetch("events").fetch("buckets")
  end
end
