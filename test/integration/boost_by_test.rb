# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/boost_by"

class BoostByTest < TinkickIntegrationTest
  class CursorValue < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
  end

  def test_default_numeric_boost_uses_natural_log_after_multiplying_the_field_value
    first = cursor("Low", price: 2, ratio: 0.5)
    second = cursor("High", price: 10, ratio: 0.5)
    values = scores(CursorValue, { price: { factor: 3 } })

    assert_in_delta 2 * Math.log(8), values.fetch(first.id), 0.000001
    assert_in_delta 2 * Math.log(32), values.fetch(second.id), 0.000001
    assert_operator values.fetch(second.id), :>, values.fetch(first.id)
  end

  def test_default_group_sums_functions_and_multiply_group_multiplies_the_result
    row = cursor("Both groups", price: 2, ratio: 6)
    spec = { price: {}, ratio: {}, id: { factor: 0.1, boost_mode: "multiply" } }
    expected = 2 * (Math.log(4) + Math.log(8)) * (row.id * 0.1)

    assert_in_delta expected, scores(CursorValue, spec).fetch(row.id), expected.abs * 0.000001
    assert_in_delta 24, scores(CursorValue, { price: { boost_mode: "multiply" }, ratio: { boost_mode: "multiply" } }).fetch(row.id), 0.000001
  end

  def test_array_option_de_duplicates_fields_before_combining_functions
    row = cursor("Once", price: 2, ratio: 0)

    assert_in_delta 2 * Math.log(4), scores(CursorValue, [:price, :price]).fetch(row.id), 0.000001
  end

  def test_missing_values_skip_functions_but_explicit_zero_and_other_replacements_are_transformed
    product = tinkick_test_products(:red_apple)

    assert_equal 2.0, scores(SearchProduct, [:ratings]).fetch(product.id)
    assert_in_delta 2 * Math.log(2), scores(SearchProduct, { ratings: { missing: 0 } }).fetch(product.id), 0.000001
    assert_in_delta 2 * Math.log(202), scores(SearchProduct, { ratings: { missing: 100, factor: 2 } }).fetch(product.id), 0.000001
    assert_equal 2.0, scores(SearchProduct, { ratings: { boost_mode: "multiply" } }).fetch(product.id)
  end

  def test_missing_one_default_function_does_not_add_a_fallback_one_to_another_function
    product = tinkick_test_products(:red_apple)
    spec = { id: { modifier: "none", factor: 0.5 }, ratings: {} }

    assert_equal product.id.to_f, scores(SearchProduct, spec).fetch(product.id)
  end

  def test_numeric_arrays_use_the_minimum_non_null_value_before_factor_and_modifier
    product = tinkick_test_products(:red_apple)
    product.update!(ratings: [9, nil, 2, 5])

    assert_equal 8.0, scores(SearchProduct, { ratings: { factor: 2, modifier: "none" } }).fetch(product.id)
    assert_equal 8.0, scores(SearchProduct, { ratings: { factor: -1, modifier: "square" } }).fetch(product.id)
    assert_equal 1.0, scores(SearchProduct, { ratings: { modifier: "reciprocal" } }).fetch(product.id)
  end

  def test_empty_and_all_null_numeric_arrays_have_missing_value_semantics
    product = tinkick_test_products(:red_apple)

    [[], [nil, nil]].each do |value|
      product.update!(ratings: value)
      assert_equal 2.0, scores(SearchProduct, [:ratings]).fetch(product.id)
      assert_in_delta 2 * Math.log(5), scores(SearchProduct, { ratings: { missing: 3 } }).fetch(product.id), 0.000001
    end
  end

  def test_all_supported_modifiers_override_the_default
    row = cursor("Modifiers", price: 2, ratio: 0)
    expected = {
      none: 4, log: Math.log10(4), log1p: Math.log10(5), log2p: Math.log10(6),
      ln: Math.log(4), ln1p: Math.log(5), ln2p: Math.log(6), square: 16, sqrt: 2, reciprocal: 0.25,
    }

    expected.each do |modifier, value|
      actual = scores(CursorValue, { price: { factor: 2, modifier: modifier.to_s } }).fetch(row.id)
      assert_in_delta value * 2, actual, 0.000001, modifier.to_s
    end
  end

  def test_negative_inputs_are_allowed_when_the_transformed_function_score_is_nonnegative
    row = cursor("Negative input", price: -0.5, ratio: -2)

    assert_in_delta 2 * Math.log(1.5), scores(CursorValue, [:price]).fetch(row.id), 0.000001
    assert_equal 8.0, scores(CursorValue, { ratio: { modifier: "square" } }).fetch(row.id)
    assert_in_delta 2 * Math.log(4), scores(CursorValue, { ratio: { factor: -1 } }).fetch(row.id), 0.000001
  end

  def test_negative_or_nan_function_outcomes_raise_instead_of_silently_changing_scores
    row = cursor("Invalid outcome", price: -1.5, ratio: Float::NAN)

    [[:price], { price: { modifier: "none" } }, { ratio: { modifier: "none" } }].each do |spec|
      assert_raises(ActiveRecord::StatementInvalid) do
        CursorValue.transaction(requires_new: true) { scores(CursorValue, spec).fetch(row.id) }
      end
    end
  end

  def test_zero_reciprocal_is_clamped_to_the_elasticsearch_default_group_maximum
    row = cursor("Reciprocal zero", price: 0, ratio: 0)
    actual = scores(CursorValue, { price: { modifier: "reciprocal" } }, base: "1.0").fetch(row.id)

    assert_in_delta 3.4028234663852886e38, actual, 1e30
  end

  def test_filtered_out_invalid_rows_are_not_scored
    valid = cursor("Valid", price: 10, ratio: 0)
    cursor("Excluded invalid", price: -10, ratio: 0)
    compiler = Tinkick::BoostBy.new(CursorValue, [:price])
    values = CursorValue.where(id: valid.id).pluck(:id, Arel.sql(compiler.score_sql("2.0"))).to_h

    assert_in_delta 2 * Math.log(12), values.fetch(valid.id), 0.000001
  end

  def test_unknown_non_numeric_fields_and_unknown_options_fail_with_actionable_errors
    [[:absent], [:name], [:tags], { price: { modifier: "unsupported" } }, { price: { mystery: 1 } }].each do |spec|
      assert_raises(ArgumentError, Tinkick::MissingFieldError) { Tinkick::BoostBy.new(CursorValue, spec) }
    end
    [Float::NAN, Float::INFINITY].each do |factor|
      assert_raises(ArgumentError) { Tinkick::BoostBy.new(CursorValue, { price: { factor: factor } }) }
    end
  end

  def test_nil_false_and_empty_boosts_leave_the_base_score_expression_unchanged
    [nil, false, [], {}].each do |spec|
      compiler = Tinkick::BoostBy.new(CursorValue, spec)

      assert compiler.empty?
      assert_equal "original_score", compiler.score_sql("original_score")
    end
  end

  private

  def cursor(name, price:, ratio:)
    CursorValue.create!(name: name, price: price, ratio: ratio,
      code: "00000000-0000-0000-0000-000000000001", recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z")
  end

  def scores(model, spec, base: "2.0")
    compiler = Tinkick::BoostBy.new(model, spec)
    model.order(:id).pluck(:id, Arel.sql(compiler.score_sql(base))).to_h
  end
end
