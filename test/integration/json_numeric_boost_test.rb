# frozen_string_literal: true

require_relative "../integration_helper"

class JsonNumericBoostTest < TinkickIntegrationTest
  HOSTILE_KEY = %q[rating'\"); SELECT 1; --]

  class Product < ActiveRecord::Base
    self.table_name = "tinkick_test_products"
    tinkick searchable: [:name]
  end

  def test_scalar_json_numbers_rank_results_without_a_separate_numeric_index
    apple, pear = products
    apple.update!(metadata: { metrics: { rating: 2.5 } })
    pear.update!(metadata: { metrics: { rating: 20 } })
    page = search("metadata.metrics.rating", factor: 2)

    assert_equal [pear.id, apple.id], page.map(&:id)
    assert_in_delta Math.log(7), scores(page).fetch(apple.id), 0.000001
    assert_in_delta Math.log(42), scores(page).fetch(pear.id), 0.000001
  end

  def test_numeric_strings_are_coerced_and_empty_strings_have_missing_semantics
    apple, pear = products
    apple.update!(metadata: { rating: " 1.25e1 " })
    pear.update!(metadata: { rating: "" })
    values = scores(search("metadata.rating", modifier: "none"))

    assert_equal 12.5, values.fetch(apple.id)
    assert_equal 1.0, values.fetch(pear.id)
    assert_equal 5.0, scores(search("metadata.rating", modifier: "none", missing: 5)).fetch(pear.id)
    apple.update!(metadata: { rating: "0" })
    assert_equal 0.0, scores(search("metadata.rating", modifier: "none")).fetch(apple.id)
  end

  def test_null_absent_and_empty_arrays_skip_functions_or_use_explicit_missing
    apple, = products

    [nil, {}, { rating: nil }, { rating: [] }, { rating: [nil, "", [nil, []]] }].each do |metadata|
      apple.update!(metadata: metadata)

      assert_equal 1.0, scores(search("metadata.rating", modifier: "none")).fetch(apple.id), metadata.inspect
      assert_equal 4.0, scores(search("metadata.rating", modifier: "none", missing: 2, factor: 2)).fetch(apple.id), metadata.inspect
    end
  end

  def test_nested_numeric_arrays_use_the_minimum_before_factor_and_modifier
    apple, = products
    apple.update!(metadata: { rating: [9, nil, ["2", [5, 3]], ""] })

    assert_equal 4.0, scores(search("metadata.rating", factor: 2, modifier: "none")).fetch(apple.id)
    assert_equal 4.0, scores(search("metadata.rating", factor: -1, modifier: "square")).fetch(apple.id)
    assert_equal 0.5, scores(search("metadata.rating", modifier: "reciprocal")).fetch(apple.id)
  end

  def test_paths_traverse_arrays_of_objects_without_reading_unrelated_numeric_keys
    apple, pear = products
    apple.update!(metadata: { offers: [[{ rating: [8, 3], unrelated: -500 }], { rating: 6 }, {}] })
    pear.update!(metadata: { offers: { rating: 5, unrelated: 1 } })
    page = search("metadata.offers.rating", modifier: "none")

    assert_equal({ apple.id => 3.0, pear.id => 5.0 }, scores(page))
    assert_equal [pear.id, apple.id], page.map(&:id)
  end

  def test_malformed_and_nonfinite_leaf_values_fail_even_when_an_array_contains_valid_numbers
    apple, = products
    invalid = [true, false, {}, { nested: 3 }, "not a number", " ", "NaN", "Infinity", "-Infinity", [1, "invalid"], [1, {}]]

    invalid.each do |value|
      apple.update!(metadata: { rating: value })
      assert_raises(ActiveRecord::StatementInvalid, value.inspect) do
        Product.transaction(requires_new: true) { search("metadata.rating", modifier: "none").to_a }
      end
    end
  end

  def test_json_boosts_do_not_score_filtered_out_invalid_values_or_change_counts
    apple, pear = products
    apple.update!(metadata: { rating: "invalid" })
    pear.update!(metadata: { rating: 8 })
    options = { boost_by: { "metadata.rating" => { modifier: "none" } } }
    page = Product.tinkick_search("*", **options)

    assert_equal 2, page.total_count
    filtered = Product.tinkick_search("*", **options, where: { id: pear.id }, load: false, select: [:name])
    assert_equal [{ "name" => pear.name }], filtered.hits.map { |hit| hit.fetch("_source") }
    assert_equal 8.0, filtered.hits.first.fetch("_score")
  end

  def test_quoted_path_components_remain_literal_keys
    apple, pear = products
    apple.update!(metadata: { HOSTILE_KEY => { "*" => 9 } })
    pear.update!(metadata: { HOSTILE_KEY => { "other" => 100 } })

    assert_equal({ apple.id => 9.0, pear.id => 1.0 }, scores(search("metadata.#{HOSTILE_KEY}.*", modifier: "none")))
    assert_equal 2, Product.count
  end

  def test_paths_require_a_real_jsonb_root_and_nonempty_keys_without_null_bytes
    ["missing.rating", "name.rating", "ratings.value", "metadata..rating", "metadata.rating.", "metadata.\0rating"].each do |path|
      assert_raises(ArgumentError, Tinkick::MissingFieldError, Tinkick::InvalidQueryError) { search(path) }
    end
  end

  def test_updates_change_json_boosted_order_without_reindexing
    apple, pear = products
    apple.update!(metadata: { rating: 2 })
    pear.update!(metadata: { rating: 3 })

    assert_equal [pear.id, apple.id], search("metadata.rating").map(&:id)
    apple.update!(metadata: { rating: 4 })
    assert_equal [apple.id, pear.id], search("metadata.rating").map(&:id)
  end

  def test_json_boost_scales_native_tin_relevance_without_removing_the_search_index
    apple, = products
    apple.update!(metadata: { rating: 8 })
    options = { fields: ["name^1"], misspellings: false }
    baseline = Product.tinkick_search("apple", **options).with_score.first.last
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    page = Product.tinkick_search("apple", **options, boost_by: ["metadata.rating"])
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal [apple.id], page.map(&:id)
      assert_in_delta baseline * Math.log(10), page.with_score.first.last, 0.000001
    end
    statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_score") }
    plan = Product.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick JSON Boost Explain", statement.fetch(:binds))

    assert_includes plan, "Text Search Scan"
    assert_includes plan, "index_tinkick_test_products_on_name"
    assert_includes plan, "Recursive Union"
  end

  private

  def products
    [:red_apple, :green_pear].map { |name| Product.find(tinkick_test_products(name).id) }
  end

  def search(path, **settings)
    Product.tinkick_search("*", boost_by: { path => settings })
  end

  def scores(relation)
    relation.with_score.to_h { |record, score| [record.id, score] }
  end
end
