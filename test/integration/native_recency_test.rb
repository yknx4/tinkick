# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/recency_boost"

class NativeRecencyTest < TinkickIntegrationTest
  ORIGIN = Time.utc(2026, 9, 17)

  class Entry < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
  end

  def test_postgresql_interval_strings_support_fractional_days_weeks_and_months
    [["1.5d", 129_600], ["2w", 1_209_600], ["1 month", 2_592_000]].each do |scale, seconds|
      entry = create_entry(at: ORIGIN - seconds)

      assert_in_delta 0.5, score(entry, scale: scale), 0.000001, scale
    end
  end

  def test_native_microseconds_are_not_truncated_to_milliseconds
    entry = create_entry(at: Time.at(Rational(-1, 10_000)).utc)

    assert_in_delta 0.5, score(entry, origin: 0, scale: "100 microseconds"), 0.000001
    assert_in_delta 1, score(entry, origin: -0.1, scale: "100 microseconds"), 0.000001
  end

  def test_large_finite_factors_are_not_clipped_to_float32
    entry = create_entry(at: ORIGIN)

    assert_in_epsilon 1e100, score(entry, scale: "1d", factor: 1e100), 0.000001
    assert_equal 0, score(entry, scale: "1d", factor: -0.0)
  end

  def test_postgresql_rejects_malformed_interval_text_without_executing_it
    entry = create_entry(at: ORIGIN)

    ["not a duration", "1d'); SELECT 1; --"].each do |scale|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        Entry.transaction(requires_new: true) { score(entry, scale: scale) }
      end
      assert_kind_of PG::InvalidDatetimeFormat, error.cause
    end
    assert Entry.exists?(entry.id)
  end

  private

  def create_entry(at:)
    Entry.create!(name: "Rivendell archive", price: 1, recorded_at: at, recorded_on: at.to_date,
      code: "00000000-0000-0000-0000-000000000001")
  end

  def score(entry, **options)
    compiler = Tinkick::RecencyBoost.new(Entry, { recorded_at: options }, now: ORIGIN)
    expression = compiler.functions.first.last
    Entry.where(id: entry.id).pick(Arel.sql(expression)).to_f
  end
end
