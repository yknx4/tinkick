# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/tinkick/aggregation_date"

class AggregationDateTest < Minitest::Test
  def test_dates_times_and_iso_strings_keep_the_requested_instant
    dates = Tinkick::AggregationDate.new(time_zone: "America/New_York")
    instant = Time.utc(2026, 1, 2)

    assert_equal dates.parse(instant), dates.parse("2026-01-02T01:00:00+01:00")
    assert_equal dates.parse(instant), dates.parse(instant.to_datetime)
    assert_equal "2026-01-01T19:00:00.000-05:00", dates.format(dates.parse(instant))
    assert_equal "2026-01-02T00:00:00.000-05:00", dates.format(dates.parse(Date.new(2026, 1, 2)))
    assert_equal dates.parse(Date.new(2026, 1, 2)), dates.parse("2026-01-02")
    assert_nil dates.parse(nil)
  end

  def test_timezone_free_iso_strings_use_standard_rails_local_time_handling
    dates = Tinkick::AggregationDate.new(time_zone: "America/New_York")
    zone = ActiveSupport::TimeZone["America/New_York"]
    ["2026-03-08T02:30:00", "2026-11-01T01:30:00"].each do |input|
      assert_equal (zone.iso8601(input).to_r * 1_000).to_f, dates.parse(input)
    end
    fixed = Tinkick::AggregationDate.new(time_zone: "+01:30")
    assert_equal Time.utc(2026, 1, 1, 22, 30).to_i * 1_000, fixed.parse("2026-01-02")
    assert_equal Time.utc(2026, 1, 2, 1, 34, 5).to_i * 1_000, fixed.parse("2026-01-02T03:04:05")
  end

  def test_numbers_always_mean_epoch_milliseconds_without_year_coercion
    dates = Tinkick::AggregationDate.new
    [2026, 2026.9, -0.5, 1_767_225_600_001].each do |value|
      assert_equal value.to_f, dates.parse(value)
    end
    assert_equal 2026, dates.parse("2026")
    assert_equal 1_767_225_600_001, dates.parse("1767225600001")
    assert_equal "1970-01-01T00:00:02.026Z", dates.format(dates.parse(2026))
  end

  def test_default_iso_and_epoch_labels_use_standard_formatting
    dates = Tinkick::AggregationDate.new
    assert_equal "2026-01-02T03:04:05.123Z", dates.format(dates.parse("2026-01-02T03:04:05.123Z"))
    epoch = Tinkick::AggregationDate.new(format: "epoch_millis")
    assert_equal "2026", epoch.format(epoch.parse("2026"))
    assert_equal dates.format(0.0), Tinkick::AggregationDate.new(format: "strict_date_optional_time").format(0.0)
  end

  def test_elasticsearch_date_math_is_rejected_with_application_time_guidance
    ["now", "now-7d/d", "2026-01-02||+1M", "2026-01-02||/d"].each do |value|
      error = assert_raises(Tinkick::NotImplementedError) { Tinkick::AggregationDate.new.parse(value) }
      assert_match(/date math/i, error.message)
      assert_match(/Time|Date/, error.message)
    end
  end

  def test_java_date_patterns_and_format_lists_are_not_reimplemented
    ["yyyy/MM/dd", "uuuuMMdd", "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "epoch_millis||strict_date_optional_time"].each do |format|
      error = assert_raises(Tinkick::NotImplementedError) { Tinkick::AggregationDate.new(format: format) }
      assert_match(/to_char|application/, error.message)
    end
  end

  def test_histogram_bounds_require_integral_finite_milliseconds
    dates = Tinkick::AggregationDate.new
    assert_equal 2026, dates.histogram_bound(2026)
    assert_equal(-1, dates.histogram_bound(-1))
    assert_nil dates.histogram_bound(nil)
    [2026.9, Float::INFINITY, Float::NAN, 2**63, -(2**63) - 1].each do |value|
      assert_raises(ArgumentError) { dates.histogram_bound(value) }
    end
  end

  def test_invalid_dates_and_timezones_remain_errors
    ["", "2026-02-30", "2026-01-02T25:00:00", "2000-01-01'); SELECT 1"].each do |value|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse(value) }
    end
    ["Not/A_Zone", "+19:00", "+01:99", Float::INFINITY, false].each do |zone|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new(time_zone: zone) }
    end
    ["", 1].each { |format| assert_raises(ArgumentError) { Tinkick::AggregationDate.new(format: format) } }
    assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse(Float::INFINITY) }
    assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse({}) }
  end
end
