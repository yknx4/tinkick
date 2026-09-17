# frozen_string_literal: true

require_relative "../integration_helper"

class DateHistogramHardBoundsValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
end

class DateHistogramHardBoundsTest < TinkickIntegrationTest
  def test_hard_bounds_round_before_testing_inclusive_minimum_and_exclusive_maximum
    [-1, 0, 999, 1_000, 1_999, 2_000, 3_000].each_with_index { |milliseconds, index| create_value(milliseconds, index) }
    buckets = search(fixed_interval: "1s", hard_bounds: { min: 750, max: 2_750 }).aggs.fetch("events").fetch("buckets")

    assert_equal [0, 1_000], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [2, 2], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_hard_bounds_compare_final_shifted_keys_instead_of_input_values
    [0, 500, 1_000, 1_500, 2_000, 2_500].each_with_index { |milliseconds, index| create_value(milliseconds, index) }
    [500, -500].each do |offset|
      buckets = search(fixed_interval: "1s", offset: offset, hard_bounds: { min: 0, max: 2_000 }).aggs.fetch("events").fetch("buckets")

      assert_equal [500, 1_500], buckets.map { |bucket| bucket.fetch("key") }, offset.to_s
      assert_equal [2, 2], buckets.map { |bucket| bucket.fetch("doc_count") }, offset.to_s
    end
  end

  def test_one_sided_and_empty_hard_bounds_preserve_the_other_side
    [0, 1_000, 2_000].each_with_index { |milliseconds, index| create_value(milliseconds, index) }
    [{ min: 1_000 }, { max: 1_000 }, {}, { min: nil, max: nil }].zip([[1_000, 2_000], [0], [0, 1_000, 2_000], [0, 1_000, 2_000]]).each do |bounds, expected|
      buckets = search(fixed_interval: "1s", hard_bounds: bounds).aggs.fetch("events").fetch("buckets")
      assert_equal expected, buckets.map { |bucket| bucket.fetch("key") }
    end
    assert_empty search(fixed_interval: "1s", hard_bounds: { min: 1_000, max: 1_000 }).aggs.fetch("events").fetch("buckets")
    assert_empty search(term: "absent", fixed_interval: "1s", hard_bounds: { min: 0, max: 2_000 }).aggs.fetch("events").fetch("buckets")
  end

  def test_extended_empty_buckets_are_not_clipped_again_after_hard_collection_bounds
    [0, 500, 1_000, 1_500, 2_000, 2_500].each_with_index { |milliseconds, index| create_value(milliseconds, index) }
    options = { fixed_interval: "1s", offset: 500, hard_bounds: { min: 0, max: 2_000 }, extended_bounds: { min: 0, max: 2_000 } }
    buckets = search(**options).aggs.fetch("events").fetch("buckets")

    assert_equal [500, 1_500, 2_500], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [2, 2, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
    assert_equal [500, 1_500], search(**options, min_doc_count: 1).aggs.fetch("events").fetch("buckets").map { |bucket| bucket.fetch("key") }
  end

  def test_extended_bounds_are_validated_against_rounded_hard_bounds
    options = { calendar_interval: :day,
                hard_bounds: { min: "2026-01-02T12:00:00Z", max: "2026-01-04T12:00:00Z" },
                extended_bounds: { min: "2026-01-02T01:00:00Z", max: "2026-01-04T23:00:00Z" } }
    buckets = search(**options).aggs.fetch("events").fetch("buckets")

    assert_equal (2..4).map { |day| Time.utc(2026, 1, day).to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
    [{ min: "2026-01-01" }, { max: "2026-01-05" }].each do |extended|
      error = assert_raises(ArgumentError) { search(**options.merge(extended_bounds: extended)).aggs }
      assert_match(/extended.*hard/i, error.message)
    end
  end

  def test_application_computed_hard_bounds_use_the_requested_timezone
    [1, 2, 3, 4].each { |month| create_value(Time.utc(2026, month, 15), month) }
    buckets = search(calendar_interval: :month, time_zone: "+01:30",
      hard_bounds: { min: Date.new(2026, 1, 1), max: Date.new(2026, 4, 1) }).aggs.fetch("events").fetch("buckets")

    assert_equal [1, 2, 3].map { |month| Time.utc(2026, month).to_i * 1_000 - 5_400_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["2026-01-01T00:00:00.000+01:30", "2026-02-01T00:00:00.000+01:30", "2026-03-01T00:00:00.000+01:30"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 1, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_iana_hard_bounds_compare_shifted_keys_across_dst
    (7..10).each { |day| create_value(Time.utc(2026, 3, day, 12), day) }
    buckets = search(calendar_interval: :day, time_zone: "America/New_York", offset: "+6h",
      hard_bounds: { min: "2026-03-08", max: "2026-03-10" }).aggs.fetch("events").fetch("buckets")

    assert_equal [Time.utc(2026, 3, 8, 11), Time.utc(2026, 3, 9, 10)].map { |instant| instant.to_i * 1_000 }, buckets.map { |bucket| bucket.fetch("key") }
    assert_equal ["2026-03-08T07:00:00.000-04:00", "2026-03-09T06:00:00.000-04:00"], buckets.map { |bucket| bucket.fetch("key_as_string") }
    assert_equal [1, 1], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_repeated_midnight_cutoff_does_not_admit_the_earlier_shifted_bucket
    [Time.utc(2026, 11, 1, 4, 30), Time.utc(2026, 11, 1, 5, 30), Time.utc(2026, 11, 2, 5, 30)]
      .each_with_index { |instant, index| create_value(instant, index) }
    buckets = search(calendar_interval: :day, time_zone: "America/Havana", offset: "-30m",
      hard_bounds: { min: Time.utc(2026, 11, 1, 4), max: Time.utc(2026, 11, 2, 5) }).aggs.fetch("events").fetch("buckets")

    assert_equal [{ "key" => Time.utc(2026, 11, 2, 4, 30).to_i * 1_000, "key_as_string" => "2026-11-01T23:30:00.000-05:00", "doc_count" => 1 }], buckets
  end

  def test_date_arrays_and_joined_rows_count_each_document_once_per_eligible_bucket
    create_value(0, 0, times: [0, 0, 999, 1_000, 2_000])
    create_value(0, 1, times: [1_000])
    create_value(0, 2, times: [])
    create_value(0, 3)
    scope = DateHistogramHardBoundsValue.where("name ==> ?", "observation").joins("CROSS JOIN generate_series(1, 2) AS duplicate_rows")
    instantiated = []
    result = nil
    ActiveSupport::Notifications.subscribed(->(*arguments) { instantiated << arguments.last[:record_count] }, "instantiation.active_record") do
      result = Tinkick::Aggregations.new(DateHistogramHardBoundsValue, scope.limit(1)).call(events: {
        date_histogram: { field: :recorded_times, fixed_interval: "1s", hard_bounds: { min: 0, max: 2_000 } }, where: { price: { gte: 0 } },
      }).fetch("events")
    end

    assert_equal [0, 1_000], result.fetch("buckets").map { |bucket| bucket.fetch("key") }
    assert_equal [1, 2], result.fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    assert_equal 4, result.fetch("doc_count")
    assert_empty instantiated
    refute scope.loaded?
  end

  def test_empty_and_null_date_arrays_only_generate_requested_extended_buckets
    create_value(0, 0, times: [])
    create_value(0, 1)
    buckets = search(field: :recorded_times, fixed_interval: "1s", hard_bounds: { min: 0, max: 2_000 },
      extended_bounds: { min: 0, max: 1_000 }).aggs.fetch("events").fetch("buckets")

    assert_equal [0, 1_000], buckets.map { |bucket| bucket.fetch("key") }
    assert_equal [0, 0], buckets.map { |bucket| bucket.fetch("doc_count") }
  end

  def test_hard_bounds_reject_invalid_shape_precision_and_reversed_unrounded_values
    [nil, [], { lower: 0 }, { min: false }, { min: "invalid" }, { min: 1.5 }, { min: Float::INFINITY },
      { max: Float::NAN }, { max: 2**63 }, { min: 2, max: 1 },
      { min: "2026-01-02T01:00:00Z", max: "2026-01-02T00:00:00Z" }].each do |bounds|
      error = assert_raises(ArgumentError) { search(calendar_interval: :day, hard_bounds: bounds).aggs }
      assert_match(/bound|date/i, error.message, bounds.inspect)
    end
  end

  private

  def create_value(value, index, times: nil)
    instant = value.is_a?(Time) ? value : Time.at(Rational(value, 1_000)).utc
    DateHistogramHardBoundsValue.create!(name: "Bounded observation", code: format("00000000-0000-0000-0000-%012d", index),
      recorded_on: instant.to_date, recorded_at: instant, recorded_times: times&.map { |milliseconds| Time.at(Rational(milliseconds, 1_000)).utc }, price: index)
  end

  def search(term: "observation", **options)
    Tinkick::Relation.new(DateHistogramHardBoundsValue, term, fields: [:name], misspellings: false, limit: 1,
      aggs: { events: { date_histogram: { field: :recorded_at }.merge(options) } })
  end
end
