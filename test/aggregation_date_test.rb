# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/tinkick/aggregation_date"

class AggregationDateTest < Minitest::Test
  def test_calendar_arithmetic_and_rounding_use_calendar_boundaries
    dates = Tinkick::AggregationDate.new

    assert_equal "2024-02-29T12:34:56.000Z", dates.format(dates.parse("2024-01-31T12:34:56Z||+1M"))
    assert_equal "2025-02-28T12:34:56.000Z", dates.format(dates.parse("2024-02-29T12:34:56Z||+1y"))
    assert_equal "2026-01-05T00:00:00.000Z", dates.format(dates.parse("2026-01-08T12:34:56Z||/w"))
    { "y" => "2026-01-01T00:00:00.000Z", "M" => "2026-02-01T00:00:00.000Z", "d" => "2026-02-08T00:00:00.000Z", "H" => "2026-02-08T12:00:00.000Z", "m" => "2026-02-08T12:34:00.000Z", "s" => "2026-02-08T12:34:56.000Z" }.each do |unit, expected|
      assert_equal expected, dates.format(dates.parse("2026-02-08T12:34:56.789Z||/#{unit}"))
    end
    assert_equal "2026-01-16T01:01:01.000Z", dates.format(dates.parse("2026-01-01||+2w+d+h+m+s"))
  end

  def test_now_is_a_single_instant_in_the_requested_time_zone
    dates = Tinkick::AggregationDate.new(time_zone: "+01:30", now: Time.utc(2026, 1, 2, 1))

    assert_equal "2026-01-02T02:30:00.000+01:30", dates.format(dates.parse("now"))
    assert_equal Time.utc(2026, 1, 1, 22, 30).to_i * 1_000, dates.parse("now/d")
    assert_equal "2026-01-01T00:00:00.000+01:30", dates.format(dates.parse("now-1d/d"))
    assert_equal dates.parse("now"), dates.parse("now")
  end

  def test_iana_zones_preserve_dst_calendar_days_and_elapsed_hours
    dates = Tinkick::AggregationDate.new(time_zone: "America/New_York")

    assert_equal "2026-03-09T00:00:00.000-04:00", dates.format(dates.parse("2026-03-08||+1d"))
    assert_equal "2026-03-09T01:00:00.000-04:00", dates.format(dates.parse("2026-03-08||+24h"))
    assert_equal 23 * 60 * 60 * 1_000, dates.parse("2026-03-08||+1d") - dates.parse("2026-03-08")
    assert_equal "2026-03-08T03:30:00.000-04:00", dates.format(dates.parse("2026-03-08T02:30:00"))
    assert_equal "2026-11-01T01:30:00.000-04:00", dates.format(dates.parse("2026-11-01T01:30:00"))
  end

  def test_explicit_offsets_and_epoch_bounds_preserve_their_instant
    dates = Tinkick::AggregationDate.new(time_zone: "America/New_York")
    instant = Time.utc(2026, 1, 2)

    assert_equal dates.parse(instant), dates.parse("2026-01-02T01:00:00+01:00")
    assert_equal dates.parse(instant), dates.parse(instant.to_i * 1_000)
    assert_equal "2026-01-01T19:00:00.000-05:00", dates.format(dates.parse(instant))
    assert_equal "2026-01-02T00:00:00.000-05:00", dates.format(dates.parse(Date.new(2026, 1, 2)))
    assert_equal dates.parse(instant), dates.parse(DateTime.new(2026, 1, 2, 1, 0, 0, Rational(1, 24)))
    assert_nil dates.parse(nil)
  end

  def test_numeric_bounds_try_a_four_digit_year_before_epoch_milliseconds
    dates = Tinkick::AggregationDate.new
    january = Time.utc(2026, 1, 1).to_i * 1_000

    assert_equal january, dates.parse(2026)
    assert_equal january, dates.parse(2026.9)
    assert_equal 12_345, dates.parse(12_345)
    assert_equal 1_767_225_600_001, dates.parse(1_767_225_600_001)
  end

  def test_invalid_dates_math_and_time_zones_raise_clear_errors
    ["Not/A_Zone", "+19:00", "+01:99", "Pacific Time (US & Canada)", 5].each do |zone|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new(time_zone: zone) }
    end
    ["", "2026-02-30", "2026-01-01T25:00:00", "now+", "now+2", "now+1q", "now/2d", "now||+1d", "2026-01-01+1d", "now+2147483648y"].each do |value|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse(value) }
    end
    assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse(Float::INFINITY) }
    assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse({}) }
  end
end
