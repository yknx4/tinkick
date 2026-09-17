# frozen_string_literal: true

require_relative "../integration_helper"

class FilterTest < TinkickIntegrationTest
  class CursorValue < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
  end

  def test_array_filters_fail_with_the_unsupported_semantics_explanation
    error = assert_raises(Tinkick::InvalidQueryError) do
      Tinkick::Filter.new(CursorValue).apply(CursorValue.all, tags: ["fruit"])
    end
    assert_includes error.message, "array or JSON semantics"
  end

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

  private

  def filter(scope, conditions)
    Tinkick::Filter.new(SearchProduct).apply(scope, conditions)
  end
end
