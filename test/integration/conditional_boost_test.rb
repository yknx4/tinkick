# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/boost_by"
require "stringio"

class ConditionalBoostTest < TinkickIntegrationTest
  def test_scalar_shorthand_multiplies_only_matching_rows_by_one_thousand
    apple, pear = products
    values = scores(name: apple.name)

    assert_equal({ apple.id => 2000.0, pear.id => 2.0 }, values)
    assert_equal 2, SearchProduct.count
  end

  def test_ranges_and_scalar_arrays_use_the_same_default_as_scalar_conditions
    apple, pear = products

    assert_equal({ apple.id => 2000.0, pear.id => 2.0 }, scores(id: apple.id..apple.id))
    assert_equal({ apple.id => 2000.0, pear.id => 2000.0 }, scores(name: [apple.name, pear.name]))
    assert_equal({ apple.id => 2.0, pear.id => 2.0 }, scores(name: []))
  end

  def test_explicit_weights_can_demote_without_filtering_out_the_match
    apple, pear = products

    assert_equal({ apple.id => 1.0, pear.id => 2.0 }, scores(name: { value: apple.name, factor: 0.5 }))
    assert_equal [pear.id, apple.id], ranked(name: { value: apple.name, factor: 0.5 })
  end

  def test_multiple_descriptors_sum_every_matching_weight_without_adding_one
    apple, pear = products
    specification = { name: [{ value: apple.name, factor: 2 }, { value: { prefix: "Red" }, factor: 3 }] }

    assert_equal({ apple.id => 10.0, pear.id => 2.0 }, scores(**specification))
  end

  def test_conditional_and_numeric_boosts_share_the_sum_before_multiply_functions
    apple, pear = products
    apple.update!(ratings: [3])
    pear.update!(ratings: [4])
    numeric = { ratings: { modifier: "none" }, id: { factor: 0, missing: 2, boost_mode: "multiply", modifier: "ln2p" } }
    values = scores(numeric: numeric, name: { value: apple.name, factor: 0.5 })

    assert_in_delta 2 * (3 + 0.5) * Math.log(2), values.fetch(apple.id), 0.000001
    assert_in_delta 2 * 4 * Math.log(2), values.fetch(pear.id), 0.000001
  end

  def test_zero_weights_have_the_upstream_identity_fallback_but_numeric_zero_does_not
    apple, pear = products
    apple.update!(ratings: [0])
    pear.update!(ratings: [5])
    condition = { name: { value: apple.name, factor: 0 } }

    assert_equal({ apple.id => 2.0, pear.id => 2.0 }, scores(**condition))
    assert_equal({ apple.id => 0.0, pear.id => 10.0 }, scores(numeric: { ratings: { modifier: "none" } }, **condition))
    assert_raises(Tinkick::MissingFieldError) { scores(absent: { value: "x", factor: 0 }) }
  end

  def test_numeric_strings_accept_decimal_and_exponent_weights
    apple, = products

    ["2.5", " 2.5e1 "].each do |factor|
      assert_equal 2 * Float(factor), scores(name: { value: apple.name, factor: factor }).fetch(apple.id)
    end
  end

  def test_descriptor_hashes_require_an_explicit_non_null_factor
    [{ value: "Red Apple" }, { value: "Red Apple", factor: nil }, { factor: nil }].each do |descriptor|
      error = assert_raises(ArgumentError) { scores(name: descriptor) }
      assert_match(/factor/, error.message)
    end
  end

  def test_negative_nonfinite_boolean_and_malformed_weights_are_rejected
    invalid = [-1, Float::NAN, Float::INFINITY, "Infinity", "+Infinity", "1e1000", true, false, "", "2x", "not numeric", [], {}]

    invalid.each do |factor|
      assert_raises(ArgumentError, factor.inspect) { scores(name: { value: "Red Apple", factor: factor }) }
    end
  end

  def test_large_finite_conditional_weights_are_not_clamped_to_float32
    apple, pear = products

    [1e100, "1e100"].each do |factor|
      values = scores(base: "1.0", name: { value: apple.name, factor: factor })
      assert_in_delta 1e100, values.fetch(apple.id), 1e90
      assert_equal 1.0, values.fetch(pear.id)
    end
  end

  def test_signed_zero_uses_the_same_behavior_as_zero
    apple, pear = products

    [-0.0, "-0", "-0.0", 0].each do |factor|
      assert_equal({ apple.id => 2.0, pear.id => 2.0 }, scores(name: { value: apple.name, factor: factor }))
    end
  end

  def test_nil_conditions_boost_missing_values_and_false_is_a_literal_json_value
    apple, pear = products
    apple.update!(metadata: { available: false })
    pear.update!(metadata: { available: true })

    assert_equal({ apple.id => 6.0, pear.id => 2.0 }, scores("metadata.available" => { value: false, factor: 3 }))
    assert_equal({ apple.id => 8.0, pear.id => 8.0 }, scores("metadata.missing" => { factor: 4 }))
  end

  def test_array_and_json_conditions_reuse_filter_eligibility
    apple, pear = products
    apple.update!(tags: ["red", "organic"], metadata: { offers: [{ price: 3 }, { price: 9 }] })
    pear.update!(tags: ["green"], metadata: { offers: [{ price: 1 }] })
    specification = { tags: { value: "organic", factor: 2 }, "metadata.offers.price" => { value: { gte: 5 }, factor: 3 } }

    assert_equal({ apple.id => 10.0, pear.id => 2.0 }, scores(**specification))
  end

  def test_hostile_text_and_json_path_values_remain_literal_data
    apple, pear = products
    hostile = %q[O'Reilly ? \\ % _'); SELECT 1; --]
    apple.update!(description: hostile, metadata: { hostile => hostile })
    specification = { description: { value: hostile, factor: 2 }, "metadata.#{hostile}" => { value: hostile, factor: 3 } }

    assert_equal({ apple.id => 10.0, pear.id => 2.0 }, scores(**specification))
    assert_equal 2, SearchProduct.count
  end

  def test_nil_false_and_empty_specifications_preserve_the_base_score
    [nil, false, {}].each do |specification|
      compiler = Tinkick::BoostBy.new(SearchProduct, nil, boost_where: specification)

      assert compiler.empty?
      assert_equal "original_score", compiler.score_sql("original_score")
    end
  end

  def test_scoring_warns_once_per_helper_about_conditional_sorting_cost
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    compiler = Tinkick::BoostBy.new(SearchProduct, nil, boost_where: { name: "Red Apple" })

    assert_empty output.string
    2.times { compiler.score_sql("1.0") }
    assert_equal 1, output.string.scan(/boost_where/).length
    assert_match(/sort|top-k/, output.string)
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def products
    [:red_apple, :green_pear].map { |name| tinkick_test_products(name) }
  end

  def scores(numeric: nil, base: "2.0", **specification)
    compiler = Tinkick::BoostBy.new(SearchProduct, numeric, boost_where: specification)
    SearchProduct.order(:id).pluck(:id, Arel.sql("(#{compiler.score_sql(base)})")).to_h
  end

  def ranked(**specification)
    compiler = Tinkick::BoostBy.new(SearchProduct, nil, boost_where: specification)
    SearchProduct.reorder(Arel.sql("#{compiler.score_sql('2.0')} DESC")).pluck(:id)
  end
end
