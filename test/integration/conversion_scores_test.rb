# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/conversion_scores"
require "stringio"

class ConversionScoresTest < TinkickIntegrationTest
  class UnmappedProduct < ActiveRecord::Base
    self.table_name = "tinkick_conversion_unused"
  end

  def test_exact_keys_add_counts_to_the_base_score
    apple, pear = products
    apple.update!(metadata: { "red apple" => 3, "Red Apple" => 100 })
    pear.update!(metadata: { "red apple" => 7 })

    assert_equal({ apple.id => 5.0, pear.id => 9.0 }, scores("red apple", case_sensitive: true))
  end

  def test_case_insensitive_lookup_sums_matching_variants
    apple, pear = products
    apple.update!(metadata: { "Apple" => 2, "APPLE" => "3", "aPpLe" => nil, "pear" => "invalid" })
    pear.update!(metadata: { "apple pie" => 100 })

    assert_equal({ apple.id => 7.0, pear.id => 2.0 }, scores("apple"))
  end

  def test_case_matching_uses_postgresql_lower_without_accent_or_unicode_normalization
    apple, = products
    apple.update!(metadata: { "CAFÉ" => 2, "café" => 3, "cafe" => 50, "cafe\u0301" => 7 })

    assert_equal 7.0, scores("Café").fetch(apple.id)
    assert_equal 52.0, scores("CAFE").fetch(apple.id)
    assert_equal 9.0, scores("CAFE\u0301").fetch(apple.id)
  end

  def test_dots_punctuation_and_whitespace_remain_part_of_the_literal_key
    apple, = products
    apple.update!(metadata: { "red.apple" => 4, "red" => { "apple" => 50 }, " red apple " => 6 })

    [true, false].each do |sensitive|
      assert_equal 6.0, scores("red.apple", case_sensitive: sensitive).fetch(apple.id)
      assert_equal 8.0, scores(" red apple ", case_sensitive: sensitive).fetch(apple.id)
      assert_equal 2.0, scores("red apple", case_sensitive: sensitive).fetch(apple.id)
    end
  end

  def test_hostile_keys_are_quoted_as_literal_values
    apple, pear = products
    term = %q[O'Reilly ? \\ % _'); SELECT 1; --]
    apple.update!(metadata: { term => 9 })
    pear.update!(metadata: { "other" => 100 })

    [true, false].each do |sensitive|
      assert_equal({ apple.id => 11.0, pear.id => 2.0 }, scores(term, case_sensitive: sensitive))
    end
    assert_equal 2, SearchProduct.count
  end

  def test_missing_sql_null_and_json_null_counts_contribute_zero
    apple, = products
    [nil, {}, { "apple" => nil }].each do |metadata|
      apple.update!(metadata: metadata)
      [true, false].each { |sensitive| assert_equal 2.0, scores("apple", case_sensitive: sensitive).fetch(apple.id) }
    end
    SearchProduct.where(id: apple.id).update_all("metadata = 'null'::jsonb")
    [true, false].each { |sensitive| assert_equal 2.0, scores("apple", case_sensitive: sensitive).fetch(apple.id) }
  end

  def test_numeric_strings_and_fractional_counts_use_native_numeric_casts
    apple, pear = products
    apple.update!(metadata: { "apple" => " 2.5e1 " })
    pear.update!(metadata: { "apple" => 0.25 })

    [true, false].each do |sensitive|
      assert_equal({ apple.id => 27.0, pear.id => 2.25 }, scores("apple", case_sensitive: sensitive))
    end
  end

  def test_factors_scale_only_the_conversion_contribution
    apple, = products
    apple.update!(metadata: { "apple" => 4 })

    [2, 2.0, BigDecimal("2"), "2e0"].each do |factor|
      assert_equal 10.0, scores("apple", factor: factor).fetch(apple.id)
    end
    [0, -0.0].each { |factor| assert_equal 2.0, scores("apple", factor: factor).fetch(apple.id) }
  end

  def test_large_counts_are_not_clamped_to_float32
    apple, = products
    apple.update!(metadata: { "apple" => "1e100" })

    assert_in_delta 2e100, scores("apple", factor: 2).fetch(apple.id), 1e90
  end

  def test_factors_require_finite_nonnegative_numeric_values
    [-1, Float::NAN, Float::INFINITY, "Infinity", "1e1000", true, false, nil, "", "bad", {}].each do |factor|
      error = assert_raises(ArgumentError) { compiler("apple", factor: factor) }
      assert_match(/finite.*nonnegative/, error.message)
    end
  end

  def test_negative_and_nonfinite_matching_counts_raise_clear_database_errors
    apple, = products
    [-1, "NaN", "Infinity", "-Infinity"].each do |value|
      apple.update!(metadata: { "apple" => value })
      [true, false].each do |sensitive|
        error = assert_raises(ActiveRecord::StatementInvalid) do
          SearchProduct.transaction(requires_new: true) { scores("apple", case_sensitive: sensitive) }
        end
        assert_match(/conversion count.*finite.*nonnegative/, error.message)
      end
    end
  end

  def test_malformed_matching_counts_raise_native_numeric_cast_errors
    apple, = products
    ["", "bad", true, false, [], [1], {}].each do |value|
      apple.update!(metadata: { "apple" => value })
      [true, false].each do |sensitive|
        error = assert_raises(ActiveRecord::StatementInvalid) do
          SearchProduct.transaction(requires_new: true) { scores("apple", case_sensitive: sensitive) }
        end
        assert_kind_of PG::InvalidTextRepresentation, error.cause
      end
    end
  end

  def test_unrelated_keys_are_never_cast_or_validated
    apple, = products
    apple.update!(metadata: { "apple" => 3, "other" => "bad", "negative" => -1, "array" => [], "object" => {} })

    [true, false].each { |sensitive| assert_equal 5.0, scores("apple", case_sensitive: sensitive).fetch(apple.id) }
  end

  def test_filtered_out_invalid_records_do_not_prevent_scoring_valid_rows
    apple, pear = products
    apple.update!(metadata: { "apple" => "invalid" })
    pear.update!(metadata: { "apple" => 5 })
    sql = compiler("apple").score_sql("2.0")

    assert_equal [[pear.id, 7.0]], SearchProduct.where(id: pear.id).pluck(:id, Arel.sql(sql))
  end

  def test_empty_fields_return_the_original_score_without_schema_queries
    statements = []
    ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last.fetch(:sql) }, "sql.active_record") do
      scorer = Tinkick::ConversionScores.new(UnmappedProduct, fields: [], term: "apple")
      assert scorer.empty?
      assert_equal "native_score", scorer.score_sql("native_score")
    end
    assert_empty statements
  end

  def test_zero_factor_returns_the_native_score_without_schema_queries_or_warnings
    statements = []
    original_logger = UnmappedProduct.logger
    output = StringIO.new
    UnmappedProduct.logger = Logger.new(output)
    native_score = "tin.score(products.ctid)"

    ActiveSupport::Notifications.subscribed(->(*args) { statements << args.last.fetch(:sql) }, "sql.active_record") do
      scorer = Tinkick::ConversionScores.new(UnmappedProduct, fields: ["metadata"], term: "apple", factor: 0)
      assert_same native_score, scorer.score_sql(native_score)
      assert scorer.empty?
    end
    assert_empty statements
    assert_empty output.string
  ensure
    UnmappedProduct.logger = original_logger
  end

  def test_column_validation_is_lazy_and_requires_real_jsonb_columns
    missing = compiler("apple", fields: ["missing"])
    refute missing.empty?
    error = assert_raises(Tinkick::MissingFieldError) { missing.score_sql("1.0") }
    assert_match(/JSONB.*migration/i, error.message)
    ["name", "ratings", "metadata.apple"].each do |field|
      scorer = compiler("apple", fields: [field])
      assert_raises(Tinkick::InvalidQueryError, Tinkick::MissingFieldError) { scorer.score_sql("1.0") }
    end
  end

  def test_sql_scoring_never_instantiates_models_and_warns_once_per_helper
    apple, = products
    apple.update!(metadata: { "Apple" => 2 })
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    instantiated = []
    scorer = compiler("apple")
    assert_empty output.string
    ActiveSupport::Notifications.subscribed(->(*args) { instantiated << args.last[:record_count] }, "instantiation.active_record") do
      2.times { SearchProduct.pluck(Arel.sql(scorer.score_sql("2.0"))) }
    end

    assert_empty instantiated
    assert_equal 1, output.string.scan(/conversion scoring/).length
    assert_match(/sort.*top-k/, output.string)
    assert_match(/JSONB.*per row/, output.string)
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def products
    [:red_apple, :green_pear].map { |name| tinkick_test_products(name) }
  end

  def compiler(term, fields: ["metadata"], factor: 1, case_sensitive: false)
    Tinkick::ConversionScores.new(SearchProduct, fields: fields, term: term, factor: factor, case_sensitive: case_sensitive)
  end

  def scores(term, **options)
    sql = compiler(term, **options).score_sql("2.0::double precision")
    SearchProduct.order(:id).pluck(:id, Arel.sql(sql)).to_h
  end
end
