# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/recency_boost"
require_relative "../../lib/tinkick/recency_boost"

class RecencyBoostTest < TinkickIntegrationTest
  NOW = Time.utc(2026, 9, 17, 12)

  class CursorValue < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
  end

  def test_default_gaussian_origin_and_factor_use_the_supplied_clock
    recent = cursor("Recent", at: NOW)
    old = cursor("Old", at: NOW - 86_400)
    values = scores(recorded_at: { scale: "1d" })

    assert_in_delta 1, values.fetch(recent.id), 0.000001
    assert_in_delta 0.5, values.fetch(old.id), 0.000001
  end

  def test_all_three_functions_equal_decay_at_scale_and_have_distinct_tails
    row = cursor("Two days", at: NOW - 172_800)
    { gauss: 0.0625, exp: 0.25, linear: 0 }.each do |function, expected|
      assert_in_delta expected, scores(recorded_at: { scale: "1d", function: function }).fetch(row.id), 0.000001
    end
    row.update!(recorded_at: NOW - 86_400)
    [:gauss, "exp", :linear].each do |function|
      assert_in_delta 0.3, scores(recorded_at: { scale: "1d", function: function, decay: 0.3 }).fetch(row.id), 0.000001
    end
  end

  def test_offset_is_a_plateau_and_past_future_distances_are_symmetric
    inside = cursor("Inside", at: NOW + 43_200)
    past = cursor("Past", at: NOW - 172_800)
    future = cursor("Future", at: NOW + 172_800)
    values = scores(recorded_at: { scale: "1d", offset: "1d", factor: 3 })

    assert_in_delta 3, values.fetch(inside.id), 0.000001
    assert_in_delta 1.5, values.fetch(past.id), 0.000001
    assert_equal values.fetch(past.id), values.fetch(future.id)
  end

  def test_date_time_and_epoch_origins_have_the_same_meaning
    row = cursor("Origin", at: NOW - 86_400)
    origins = [NOW, NOW.to_datetime, NOW.iso8601, (NOW.to_r * 1_000).to_i]
    origins.each do |origin|
      assert_in_delta 0.5, scores(recorded_at: { origin: origin, scale: "1d" }).fetch(row.id), 0.000001, origin.inspect
    end
    assert_in_delta 0.5, scores(recorded_on: { origin: Date.new(2026, 9, 18), scale: "1d" }).fetch(row.id), 0.000001
  end

  def test_date_values_and_origins_use_millisecond_precision_before_epoch
    row = cursor("Milliseconds", at: Time.at(Rational(-1, 10_000)).utc)
    values = scores(recorded_at: { origin: 0, scale: "1ms" })

    assert_in_delta 0.5, values.fetch(row.id), 0.000001
    assert_in_delta 1, scores(recorded_at: { origin: -0.1, scale: "1ms" }).fetch(row.id), 0.000001
  end

  def test_date_arrays_choose_the_nearest_value_not_the_earliest
    row = cursor("Dates", times: [NOW - 864_000, nil, NOW + 86_400, NOW - 172_800])

    assert_in_delta 0.5, scores(recorded_times: { scale: "1d" }).fetch(row.id), 0.000001
    assert_in_delta 1, scores(recorded_times: { scale: "1d", offset: "1d" }).fetch(row.id), 0.000001
  end

  def test_null_empty_and_all_null_date_arrays_contribute_the_full_weight
    row = cursor("Missing")
    [nil, [], [nil, nil]].each do |value|
      row.update!(recorded_times: value)
      assert_in_delta 4, scores(recorded_times: { scale: "1d", factor: 4 }).fetch(row.id), 0.000001
    end
  end

  def test_date_scales_accept_integer_time_units_and_truncate_submilliseconds
    row = cursor("One millisecond", at: NOW - Rational(1, 1_000))
    ["1ms", "1000micros", "1000000nanos"].each do |scale|
      assert_in_delta 0.5, scores(recorded_at: { scale: scale }).fetch(row.id), 0.000001
    end
    row.update!(recorded_at: NOW - 86_400)
    ["86400000ms", "86400s", "1440m", "24h", "1d", "1D"].each do |scale|
      assert_in_delta 0.5, scores(recorded_at: { scale: scale, offset: 0 }).fetch(row.id), 0.000001
    end
  end

  def test_numeric_scalar_and_array_fields_share_the_decay_formulas
    row = cursor("Numeric", price: 8)
    assert_in_delta 0.5, scores(price: { origin: "10", scale: "2" }).fetch(row.id), 0.000001
    assert_in_delta 1, scores(price: { origin: 10, scale: 2, offset: 2 }).fetch(row.id), 0.000001

    product = tinkick_test_products(:red_apple)
    product.update!(ratings: [1, nil, 8, 100])
    compiler = Tinkick::RecencyBoost.new(SearchProduct, { ratings: { origin: 10, scale: 2 } })
    assert_in_delta 0.5, score_for(SearchProduct, compiler).fetch(product.id), 0.000001
    product.update!(ratings: [])
    assert_in_delta 1, score_for(SearchProduct, compiler).fetch(product.id), 0.000001
  end

  def test_factor_zero_numeric_strings_and_false_or_nil_defaults
    row = cursor("Factor")
    { 0 => 0, "2.5" => 2.5, nil => 1, false => 1 }.each do |factor, expected|
      assert_in_delta expected, scores(recorded_at: { scale: "1d", factor: factor }).fetch(row.id), 0.000001
    end
  end

  def test_multiple_fields_return_separate_unfiltered_sum_functions
    row = cursor("Multiple", at: NOW - 86_400)
    compiler = Tinkick::RecencyBoost.new(CursorValue, {
      recorded_at: { scale: "1d" }, recorded_on: { origin: Date.new(2026, 9, 18), scale: "1d", factor: 3 },
    }, now: NOW)

    assert_equal ["TRUE", "TRUE"], compiler.functions.map(&:first)
    assert_equal [1.0, 3.0], compiler.weights
    refute compiler.empty?
    assert_in_delta 2, score_for(CursorValue, compiler).fetch(row.id), 0.000001
  end

  def test_nil_false_and_empty_specs_return_no_functions
    [nil, false, {}].each do |spec|
      instance = Tinkick::RecencyBoost.new(CursorValue, spec)
      assert instance.empty?
      assert_empty instance.functions
    end
  end

  def test_missing_fields_and_non_numeric_non_date_columns_have_actionable_errors
    error = assert_raises(Tinkick::MissingFieldError) { compiler(absent: { scale: "1d" }) }
    assert_match(/Rails migration/, error.message)
    [:name, :tags, :code].each do |field|
      assert_raises(ArgumentError) { compiler(field => { scale: "1d" }) }
    end
  end

  def test_missing_scale_null_options_and_unaccepted_parameters_raise
    [{}, { scale: nil }, { scale: "1d", origin: nil }, { scale: "1d", offset: nil }, { scale: "1d", decay: nil },
      { scale: "1d", function: nil }, { scale: "1d", function: "unknown" }, { scale: "1d", multi_value_mode: "max" },
      { scale: "1d", format: "epoch_millis" }].each do |options|
      assert_raises(ArgumentError) { compiler(recorded_at: options) }
    end
    assert_raises(ArgumentError) { compiler(price: { scale: 1 }) }
    assert_raises(ArgumentError) { Tinkick::RecencyBoost.new(CursorValue, [:recorded_at]) }
    assert_raises(ArgumentError) { compiler(recorded_at: 1) }
  end

  def test_scales_offsets_decay_and_weights_are_validated_without_coercing_invalid_values
    [0, 86_400_000, "86400000", "0d", "-1d", "1w", "1M", "1.5d", "1micros"].each do |scale|
      assert_raises(ArgumentError) { compiler(recorded_at: { scale: scale }) }
    end
    [-1, 0, 1, 2, Float::NAN, Float::INFINITY, "hostile'"].each do |decay|
      assert_raises(ArgumentError) { compiler(recorded_at: { scale: "1d", decay: decay }) }
    end
    [-1, -0.0, Float::NAN, true, "not a number"].each do |factor|
      assert_raises(ArgumentError) { compiler(recorded_at: { scale: "1d", factor: factor }) }
    end
    assert_raises(ArgumentError) { compiler(recorded_at: { scale: "1d", offset: "-1ms" }) }
    assert_raises(ArgumentError) { compiler(price: { origin: 0, scale: 0 }) }
    assert_raises(ArgumentError) { compiler(price: { origin: 0, scale: 1, offset: -1 }) }
  end

  def test_hostile_field_and_origin_values_never_become_sql
    assert_raises(Tinkick::MissingFieldError) { compiler("recorded_at); SELECT 1; --" => { scale: "1d" }) }
    assert_raises(ArgumentError) { compiler(recorded_at: { origin: "hostile'); SELECT 1; --", scale: "1d" }) }
    assert_raises(ArgumentError) { compiler(price: { origin: "1); SELECT 1; --", scale: 1 }) }
    assert_equal 2, SearchProduct.count
  end

  def test_far_away_dates_decay_to_zero_without_postgresql_numeric_underflow
    row = cursor("Distant", at: Time.utc(1))
    [:gauss, :exp, :linear].each do |function|
      assert_equal 0, scores(recorded_at: { scale: "1ms", function: function }).fetch(row.id)
    end
  end

  def test_compilation_warns_once_about_scoring_and_date_array_cost
    original_logger = CursorValue.logger
    output = StringIO.new
    CursorValue.logger = Logger.new(output)
    instance = compiler(recorded_times: { scale: "1d" })
    instance.functions
    instance.functions

    assert_equal 1, output.string.scan(/recency/).length
    assert_match(/native TIN top-k/, output.string)
    assert_match(/array/i, output.string)
  ensure
    CursorValue.logger = original_logger
  end

  def test_date_math_origins_require_application_computed_times
    ["now", "now/d+12h", "2026-09-16T12:00:00Z||+1d"].each do |origin|
      error = assert_raises(Tinkick::NotImplementedError) { compiler(recorded_at: { origin: origin, scale: "1d" }) }
      assert_includes error.message, "Compute a Time or Date boundary"
    end
  end

  private


  def cursor(name, at: NOW, price: 0, times: nil)
    CursorValue.create!(name: name, recorded_at: at, recorded_on: "2026-09-17", price: price, recorded_times: times,
      code: "00000000-0000-0000-0000-000000000001")
  end

  def compiler(spec)
    Tinkick::RecencyBoost.new(CursorValue, spec, now: NOW)
  end

  def scores(spec)
    score_for(CursorValue, compiler(spec))
  end

  def score_for(model, instance)
    sql = instance.functions.map { |_presence, expression| "(#{expression})" }.join(" + ")
    model.order(:id).pluck(:id, Arel.sql("(#{sql})")).to_h
  end
end
