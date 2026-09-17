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

  def test_custom_numeric_date_formats_parse_render_and_support_date_math
    dates = Tinkick::AggregationDate.new(format: "yyyy/MM/dd")

    assert_equal Time.utc(2026, 2, 3).to_i * 1_000, dates.parse("2026/02/03")
    assert_equal "2026/03/01", dates.format(dates.parse("2026/02/03||+1M/M"))
    assert_equal "2026/02/03", dates.format(dates.parse(Time.utc(2026, 2, 3, 12)))
    compact = Tinkick::AggregationDate.new(format: "uuuuMMdd")
    assert_equal Time.utc(2026, 1, 2).to_i * 1_000, compact.parse(20260102)
    assert_equal "20260102", compact.format(compact.parse(20260102))
  end

  def test_missing_custom_components_use_epoch_date_and_midnight_defaults
    month = Tinkick::AggregationDate.new(format: "MM-yyyy", time_zone: "+01:30")
    clock = Tinkick::AggregationDate.new(format: "HH:mm")

    assert_equal Time.utc(2026, 1, 31, 22, 30).to_i * 1_000, month.parse("02-2026")
    assert_equal Time.utc(1970, 1, 1, 13, 45).to_i * 1_000, clock.parse("13:45")
    assert_equal Time.utc(2026).to_i * 1_000, Tinkick::AggregationDate.new(format: "yyyy").parse("2026")
  end

  def test_custom_clock_fractions_offsets_and_quoted_literals
    dates = Tinkick::AggregationDate.new(format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", time_zone: "America/New_York")
    expected = Time.utc(2026, 1, 2, 1, 34, Rational(5123, 1000))

    assert_equal (expected.to_r * 1_000).to_f, dates.parse("2026-01-02T03:04:05.123+01:30")
    assert_equal "2026-01-01T20:34:05.123-05:00", dates.format(dates.parse(expected))
    quoted = Tinkick::AggregationDate.new(format: "yyyy 'year''s' MM '100%' dd '' HH:mm:ssXXX")
    assert_equal "2026 year's 01 100% 02 ' 01:34:05Z", quoted.format(quoted.parse(expected))
    assert_equal Time.utc(2026, 1, 2, 1, 34, 5).to_i * 1_000, quoted.parse("2026 year's 01 100% 02 ' 01:34:05Z")
  end

  def test_fraction_width_is_exact_and_output_truncates
    { "S" => "1", "SS" => "12", "SSS" => "129" }.each do |token, fraction|
      dates = Tinkick::AggregationDate.new(format: "yyyy-MM-dd HH:mm:ss.#{token}")

      assert_equal "2026-01-02 03:04:05.#{fraction}", dates.format(dates.parse(Time.utc(2026, 1, 2, 3, 4, Rational(5129, 1000))))
      assert_equal (Time.utc(2026, 1, 2, 3, 4, 5).to_r * 1_000 + Rational(fraction.to_i, 10**fraction.length) * 1_000).to_f,
        dates.parse("2026-01-02 03:04:05.#{fraction}")
      assert_raises(ArgumentError) { dates.parse("2026-01-02 03:04:05.#{fraction}0") }
    end
  end

  def test_format_alternatives_try_in_order_and_print_with_the_first
    dates = Tinkick::AggregationDate.new(format: "yyyy/MM/dd||epoch_millis||strict_date_optional_time")
    epoch = Time.utc(2026, 1, 2).to_i * 1_000

    ["2026/01/02", epoch, "2026-01-02T00:00:00Z"].each do |value|
      assert_equal epoch, dates.parse(value)
      assert_equal "2026/01/02", dates.format(dates.parse(value))
    end
    milliseconds = Tinkick::AggregationDate.new(format: "epoch_millis", time_zone: "+01:30")
    assert_equal 2026, milliseconds.parse(2026.9)
    assert_equal "2026", milliseconds.format(milliseconds.parse("2026"))
  end

  def test_default_strict_iso_and_epoch_string_formats
    dates = Tinkick::AggregationDate.new

    assert_equal dates.parse(2026), dates.parse("2026")
    assert_equal Time.utc(2026, 2).to_i * 1_000, dates.parse("2026-02")
    assert_equal 1_767_225_600_001, dates.parse("1767225600001")
    assert_equal "2026-01-02T03:04:05.123Z", dates.format(dates.parse("2026-01-02T03:04:05,123Z"))
    ["2026-2-03", "2026-02-3", "2026-002", "2026-01-02tail"].each do |value|
      assert_raises(ArgumentError) { dates.parse(value) }
    end
  end

  def test_invalid_formats_and_custom_dates_fail_clearly
    ["", "yyyy||", "||yyyy", "yyyy#MM", "yyyy 'unfinished", "yy-MM-dd", "MMMM", "yyyy-MM-dd[HH]", "SSSS", 1].each do |pattern|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new(format: pattern) }
    end
    dates = Tinkick::AggregationDate.new(format: "yyyy-MM-dd HH:mm:ss.SSSXXX")
    ["2026-02-30 01:02:03.123Z", "2026-01-02 24:02:03.123Z", "2026-01-02 01:60:03.123Z", "2026-01-02 01:02:60.123Z", "2026-01-02 01:02:03.123+01:99", "2026-01-02 01:02:03.123+19:00", "2026-1-02 01:02:03.123Z", "2026-01-02 01:02:03.1Z", "2026-01-02 01:02:03.123Ztail"].each do |value|
      assert_raises(ArgumentError) { dates.parse(value) }
    end
  end

  def test_fixed_time_zone_forms_normalize_to_seconds_without_changing_iana_dates
    {
      nil => 0, 'UTC' => 0, 'Z' => 0, 'UT' => 0, 'GMT' => 0, 0 => 0,
      1 => 3_600, 1.9 => 3_600, -1.9 => -3_600,
      '+1' => 3_600, '+01' => 3_600, '+0130' => 5_400, '+01:30' => 5_400,
      '+013015' => 5_415, '+01:30:15' => 5_415, 'UTC+01:30' => 5_400,
      'GMT-01:30' => -5_400, 'UT+01' => 3_600,
    }.each do |zone, seconds|
      assert_equal seconds, Tinkick::AggregationDate.new(time_zone: zone).fixed_offset
    end
    assert_nil Tinkick::AggregationDate.new(time_zone: 'America/New_York').fixed_offset
  end

  def test_default_date_format_matches_upstream_labels_for_second_precision_offsets
    positive = Tinkick::AggregationDate.new(time_zone: '+00:30:37')
    negative = Tinkick::AggregationDate.new(time_zone: '-000001')

    # ES's actual strict_date_optional_time printer omits offset seconds.
    assert_equal '1970-01-01T00:30:37.000+00:30', positive.format(0.0)
    assert_equal '1969-12-31T23:59:59.000Z', negative.format(0.0)
    assert_equal(-1_837_000.0, positive.parse('1970-01-01T00:00:00'))
    assert_equal 1_000.0, negative.parse('1970-01-01T00:00:00')
    custom = Tinkick::AggregationDate.new(format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", time_zone: '-00:00:01')
    assert_equal '1969-12-31T23:59:59.000Z', custom.format(0.0)
  end

  def test_fixed_offsets_validate_components_and_finite_numeric_hours
    [false, true, 19, -19, Float::INFINITY, Float::NAN, '+18:00:01', '+12:60', '+00:00:60',
      'UTCjunk', 'UTC+1:2', '+012', '+00:0', '1'].each do |zone|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new(time_zone: zone) }
    end
  end

  def test_invalid_dates_math_and_time_zones_raise_clear_errors
    ["Not/A_Zone", "+19:00", "+01:99", "Pacific Time (US & Canada)", 19].each do |zone|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new(time_zone: zone) }
    end
    ["", "2026-02-30", "2026-01-01T25:00:00", "now+", "now+2", "now+1q", "now/2d", "now||+1d", "2026-01-01+1d", "now+2147483648y"].each do |value|
      assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse(value) }
    end
    assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse(Float::INFINITY) }
    assert_raises(ArgumentError) { Tinkick::AggregationDate.new.parse({}) }
  end
end
