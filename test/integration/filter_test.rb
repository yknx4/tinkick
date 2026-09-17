# frozen_string_literal: true

require_relative "../integration_helper"
require "logger"
require "stringio"

class FilterTest < TinkickIntegrationTest
  def test_equality_preserves_the_tin_scope
    scope = SearchProduct.where("description ==> ?", "fruit")

    assert_equal(["Red Apple"], filter(scope, name: "Red Apple").pluck(:name))
    assert_equal(2, scope.count)
    assert_empty(filter(SearchProduct.where("name ==> ?", "pear"), name: "Red Apple"))
  end

  def test_null_equality
    tinkick_test_products(:red_apple).update!(description: nil)

    assert_equal(["Red Apple"], filter(SearchProduct.all, description: nil).pluck(:name))
  end

  def test_including_values_and_null
    tinkick_test_products(:red_apple).update!(description: nil)

    assert_equal(["Green Pear", "Red Apple"], filter(SearchProduct.all, description: ["Ripe fruit", nil]).order(:name).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, description: { in: ["Ripe fruit"] }).pluck(:name))
    assert_empty(filter(SearchProduct.all, name: []))
  end

  def test_not_includes_null_values
    tinkick_test_products(:red_apple).update!(description: nil)

    assert_equal(["Red Apple"], filter(SearchProduct.all, description: { not: "Ripe fruit" }).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, description: { _not: nil }).pluck(:name))
    assert_empty(filter(SearchProduct.all, description: { not: [nil, "Ripe fruit"] }))
  end

  def test_range_bounds
    assert_equal(["Green Pear", "Red Apple"], filter(SearchProduct.all, name: "Green Pear".."Red Apple").order(:name).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, name: "Green Pear"..."Red Apple").pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, name: "Red Apple"..).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, name: ..."Red Apple").pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, name: { gt: "Green Pear", lte: "Red Apple" }).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, name: { gte: "Green Pear", lt: "Red Apple" }).pluck(:name))
  end

  def test_boolean_groups
    conditions = { _and: [{ _or: [{ name: "Red Apple" }, { name: "Green Pear" }] }, { description: "Ripe fruit" }] }

    assert_equal(["Green Pear"], filter(SearchProduct.all, conditions).pluck(:name))
  end

  def test_not_excludes_each_field_separately
    conditions = { _not: { name: "Red Apple", description: "Ripe fruit" } }

    assert_empty(filter(SearchProduct.all, conditions))
  end

  def test_not_over_a_boolean_group
    tinkick_test_products(:red_apple).update!(description: nil)
    conditions = { _not: { _or: [{ name: "Green Pear" }, { description: "Missing" }] } }

    assert_equal(["Red Apple"], filter(SearchProduct.all, conditions).pluck(:name))
  end

  def test_empty_conditions_preserve_all_rows
    assert_equal(2, filter(SearchProduct.all, {}).count)
  end

  def test_values_cannot_change_the_sql_predicate
    assert_empty(filter(SearchProduct.all, name: "Red Apple' OR 1=1 --"))
    assert_empty(filter(SearchProduct.all, name: "Red%"))
    assert_empty(filter(SearchProduct.all, name: ["Red Apple' OR 1=1 --"]))
  end

  def test_missing_fields_raise_migration_guidance
    error = assert_raises(Tinkick::MissingFieldError) do
      filter(SearchProduct.all, "name) OR TRUE --" => "Red Apple")
    end

    assert_includes(error.message, "SearchProduct")
    assert_includes(error.message, "name) OR TRUE --")
    assert_includes(error.message, "migration")
  end

  def test_unknown_operators_fail
    assert_raises(ArgumentError) { filter(SearchProduct.all, name: { contains: "Red" }) }
    assert_raises(ArgumentError) { filter(SearchProduct.all, name: { "gt" => "Red" }) }
  end

  def test_exists_distinguishes_null_from_empty_text
    tinkick_test_products(:red_apple).update!(description: nil)
    tinkick_test_products(:green_pear).update!(description: "")

    assert_equal(["Green Pear"], filter(SearchProduct.all, description: { exists: true }).pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, description: { exists: false }).pluck(:name))
    [nil, "true", 1].each do |value|
      error = assert_raises(ArgumentError) { filter(SearchProduct.all, description: { exists: value }) }
      assert_equal("Passing a value other than true or false to exists is not supported", error.message)
    end
  end

  def test_all_requires_every_requested_value
    assert_equal(["Red Apple"], filter(SearchProduct.all, name: { all: ["Red Apple", "Red Apple"] }).pluck(:name))
    assert_empty(filter(SearchProduct.all, name: { all: ["Red Apple", "Green Pear"] }))
    assert_equal(2, filter(SearchProduct.all, name: { all: [] }).count)
    assert_raises(ArgumentError) { filter(SearchProduct.all, name: { all: "Red Apple" }) }

    tinkick_test_products(:red_apple).update!(description: nil)
    assert_equal(["Red Apple"], filter(SearchProduct.all, description: { all: [nil] }).pluck(:name))
  end

  def test_negating_all_excludes_each_requested_value
    assert_empty(filter(SearchProduct.all, _not: { name: { all: ["Red Apple", "Green Pear"] } }))
  end

  def test_like_and_ilike_match_the_whole_field_with_wildcards
    scope = SearchProduct.where("description ==> ?", "fruit")

    assert_equal(["Red Apple"], filter(scope, name: { like: "%Apple" }).pluck(:name))
    assert_equal(["Red Apple"], filter(scope, name: { like: "Red_Apple" }).pluck(:name))
    assert_empty(filter(scope, name: { like: "Apple" }))
    assert_empty(filter(scope, name: { like: "red%" }))
    assert_equal(["Red Apple"], filter(scope, name: { ilike: "red%" }).pluck(:name))
  end

  def test_like_escapes_wildcards_but_preserves_other_backslashes
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Product 100%_\\ABC")

    assert_equal([product.id], filter(SearchProduct.all, name: { like: "Product 100\\%\\_\\A%" }).ids)
    assert_equal([product.id], filter(SearchProduct.all, name: { ilike: "product 100\\%\\_\\a%" }).ids)
    assert_empty(filter(SearchProduct.all, name: { like: "Product 100\\%\\_A%" }))

    product.update!(name: "Product\\")
    assert_equal([product.id], filter(SearchProduct.all, name: { like: "Product\\" }).ids)
  end

  def test_like_does_not_interpret_regular_expression_syntax
    product = tinkick_test_products(:red_apple)
    product.update!(name: "Product.[ABC](red)+?")

    assert_equal([product.id], filter(SearchProduct.all, name: { like: "Product.[ABC](red)+?" }).ids)
    assert_empty(filter(SearchProduct.all, name: { like: "Product.Ared" }))
  end

  def test_prefix_is_case_sensitive_and_treats_wildcards_literally
    assert_equal(["Red Apple"], filter(SearchProduct.all, name: { prefix: "Red" }).pluck(:name))
    assert_empty(filter(SearchProduct.all, name: { prefix: "red" }))
    assert_empty(filter(SearchProduct.all, name: { prefix: "R%" }))

    product = tinkick_test_products(:red_apple)
    product.update!(name: "100%_\\Value")
    assert_equal([product.id], filter(SearchProduct.all, name: { prefix: "100%_\\" }).ids)
  end

  def test_negated_text_filters_include_null
    tinkick_test_products(:red_apple).update!(description: nil)

    assert_equal(["Red Apple"], filter(SearchProduct.all, _not: { description: { like: "Ripe%" } }).pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, _not: { description: { prefix: "Ripe" } }).pluck(:name))
  end

  def test_text_filter_values_remain_bound
    [:like, :ilike, :prefix].each do |operator|
      assert_empty(filter(SearchProduct.all, name: { operator => "Red%' OR TRUE --" }))
      assert_raises(TypeError) { filter(SearchProduct.all, name: { operator => ["Red"] }) }
    end
  end

  def test_legacy_or_combines_alternative_groups_with_and
    conditions = {
      or: [
        [{ name: "Red Apple" }, { name: "Green Pear" }],
        [{ description: "Fresh orchard fruit" }, { name: "Missing" }],
      ],
    }

    assert_equal(["Red Apple"], filter(SearchProduct.all, conditions).pluck(:name))
    assert_equal(2, filter(SearchProduct.all, or: []).count)
    assert_raises(ArgumentError) { filter(SearchProduct.all, or: [{ name: "Red Apple" }]) }
  end

  def test_array_membership_and_all_preserve_the_tin_scope
    set_array_values
    scope = SearchProduct.where("description ==> ?", "fruit")

    assert_equal(["Red Apple"], filter(scope, tags: "red").pluck(:name))
    assert_equal(["Green Pear", "Red Apple"], filter(scope, tags: ["red", "green"]).order(:name).pluck(:name))
    assert_equal(["Green Pear"], filter(scope, tags: { in: ["green"] }).pluck(:name))
    assert_equal(["Red Apple"], filter(scope, tags: { all: ["fruit", "red", "red"] }).pluck(:name))
    assert_empty(filter(scope, tags: { all: ["red", "green"] }))
    assert_empty(filter(scope, tags: []))
    assert_equal(2, filter(scope, tags: { all: [] }).count)
    assert_empty(filter(scope.where("name ==> ?", "pear"), tags: "red"))
  end

  def test_array_null_and_exists_ignore_null_elements
    set_array_values
    SearchProduct.create!(name: "Empty", tags: [])
    SearchProduct.create!(name: "Missing", tags: nil)
    SearchProduct.create!(name: "Null entries", tags: [nil, nil])
    absent = ["Empty", "Missing", "Null entries"]

    assert_equal(absent, filter(SearchProduct.all, tags: nil).order(:name).pluck(:name))
    assert_equal(absent, filter(SearchProduct.all, tags: { exists: false }).order(:name).pluck(:name))
    assert_equal(["Green Pear", "Red Apple"], filter(SearchProduct.all, tags: { exists: true }).order(:name).pluck(:name))
    assert_equal(absent + ["Red Apple"], filter(SearchProduct.all, tags: [nil, "red"]).order(:name).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, tags: { not: [nil, "red"] }).pluck(:name))
    assert_empty(filter(SearchProduct.all, tags: { all: [nil, "red"] }))
  end

  def test_array_negation_preserves_individual_predicates
    set_array_values
    SearchProduct.create!(name: "Missing", tags: nil)

    assert_equal(["Green Pear", "Missing"], filter(SearchProduct.all, tags: { not: "red" }).order(:name).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, tags: { not: ["red"], in: ["fruit"] }).pluck(:name))
    assert_equal(["Missing"], filter(SearchProduct.all, _not: { tags: { all: ["red", "green"] } }).pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, _and: [{ tags: "fruit" }, { _not: { tags: "green" } }]).pluck(:name))
  end

  def test_array_range_bounds_must_match_the_same_element
    set_array_values

    assert_equal(["Red Apple"], filter(SearchProduct.all, ratings: { gt: 26, lt: 36 }).pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, ratings: 26...36).pluck(:name))
    assert_empty(filter(SearchProduct.all, ratings: 20...32))
    assert_equal(["Red Apple"], filter(SearchProduct.all, ratings: 20..32).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, ratings: ...19).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, ratings: 43..).pluck(:name))
    assert_equal(["Green Pear"], filter(SearchProduct.all, _not: { ratings: { gt: 26, lt: 36 } }).pluck(:name))
  end

  def test_multidimensional_arrays_match_flattened_values
    tinkick_test_products(:red_apple).update!(tags: [["fruit", "red"], [nil, "ripe"]], ratings: [[1, 19], [32, 42]])

    assert_equal(["Red Apple"], filter(SearchProduct.all, tags: { all: ["fruit", "ripe"] }).pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, tags: { exists: true }).pluck(:name))
    assert_equal(["Red Apple"], filter(SearchProduct.all, ratings: 30..35).pluck(:name))
  end

  def test_array_text_filters_and_values_remain_bound
    set_array_values
    product = tinkick_test_products(:red_apple)
    product.update!(tags: ["Product 100%_\\ABC", "red"])

    assert_equal([product.id], filter(SearchProduct.all, tags: { like: "Product 100\\%\\_\\A%" }).ids)
    assert_equal([product.id], filter(SearchProduct.all, tags: { ilike: "product%" }).ids)
    assert_equal([product.id], filter(SearchProduct.all, tags: { prefix: "Product 100%_\\" }).ids)
    assert_empty(filter(SearchProduct.all, tags: "red']::text[] OR TRUE --"))
    assert_empty(filter(SearchProduct.all, tags: { prefix: "red') OR TRUE --" }))
  end

  def test_array_membership_can_use_a_gin_index
    set_array_values
    SearchProduct.with_connection do |connection|
      connection.execute("SET LOCAL enable_seqscan = off")
      relation = filter(SearchProduct.all, tags: "red")
      plan = connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")

      assert_includes(plan, "index_tinkick_test_products_on_tags")
      assert_includes(plan, "Index Cond")
    end
  end

  def test_array_element_scans_warn_but_membership_does_not
    set_array_values
    output = StringIO.new
    original_logger = SearchProduct.logger
    SearchProduct.logger = Logger.new(output, level: Logger::WARN)

    filter(SearchProduct.all, tags: "red").load
    assert_empty(output.string)
    filter(SearchProduct.all, ratings: 26..36).load
    assert_includes(output.string, "array elements")
    assert_includes(output.string, "GIN")
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def filter(scope, conditions)
    Tinkick::Filter.new(SearchProduct).apply(scope, conditions)
  end

  def set_array_values
    tinkick_test_products(:red_apple).update!(tags: ["fruit", "red", nil], ratings: [19, 32, 42])
    tinkick_test_products(:green_pear).update!(tags: ["fruit", "green"], ratings: [13, 40, 52])
  end
end
