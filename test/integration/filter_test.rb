# frozen_string_literal: true

require_relative "../integration_helper"

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

  private

  def filter(scope, conditions)
    Tinkick::Filter.new(SearchProduct).apply(scope, conditions)
  end
end
