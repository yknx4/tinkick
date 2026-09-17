# frozen_string_literal: true

require_relative "../integration_helper"

class RecursiveJsonFilterTest < TinkickIntegrationTest
  def test_deep_scalar_arrays_support_membership_all_negation_and_tin
    tinkick_test_products(:red_apple).update!(metadata: { tags: [[["red", ["fruit"]]], nil] })
    tinkick_test_products(:green_pear).update!(metadata: { tags: [[["green", "fruit"]]] })

    assert_equal ["Red Apple"], names("metadata.tags" => "red")
    assert_equal ["Green Pear", "Red Apple"], names("metadata.tags" => { in: ["red", "green"] })
    assert_equal ["Red Apple"], names("metadata.tags" => { all: ["red", "fruit"] })
    assert_equal ["Green Pear"], names("metadata.tags" => { not: "red" })
    assert_empty Tinkick::Relation.new(SearchProduct, "pear", fields: [:name], misspellings: false,
      where: { "metadata.tags" => "red" }).to_a
  end

  def test_deep_object_arrays_advance_only_the_requested_path
    tinkick_test_products(:red_apple).update!(metadata: [[[{ variants: [[[{ color: [["red"]], size: "small" },
      { color: "green", size: [["large"]] }]]] }]]])
    tinkick_test_products(:green_pear).update!(metadata: { wrong: { variants: [{ color: "red", size: "large" }] },
      variants: [[[{ wrong: { color: "red" }, color: "yellow", size: "large" }]]] })

    assert_equal ["Red Apple"], names("metadata.variants.color" => "red", "metadata.variants.size" => "large")
    assert_equal ["Red Apple"], names("metadata.variants.color" => { all: ["red", "green"] })
    assert_equal ["Green Pear"], names("metadata.variants.color" => { not: "red" })
    assert_empty names("metadata.variants" => "red")
  end

  def test_range_bounds_match_one_scalar_leaf_without_type_coercion
    tinkick_test_products(:red_apple).update!(metadata: { ratings: [[[5], [1, 10]]] })
    tinkick_test_products(:green_pear).update!(metadata: { ratings: [[[1], [10]], [["5"]]] })

    assert_equal ["Red Apple"], names("metadata.ratings" => { gt: 3, lt: 7 })
    assert_equal ["Red Apple"], names("metadata.ratings" => 3...7)
    assert_equal ["Green Pear"], names(_not: { "metadata.ratings" => { gt: 3, lt: 7 } })
    assert_empty names("metadata.ratings" => 6..9)
  end

  def test_patterns_and_quoted_keys_visit_deep_string_leaves
    key = "quoted\" ? (@ == 1) --"
    tinkick_test_products(:red_apple).update!(metadata: { key => [[["Product 100%_\\ABC"]]] })
    tinkick_test_products(:green_pear).update!(metadata: { key => [[[123]]] })
    field = "metadata.#{key}"

    assert_equal ["Red Apple"], names(field => { like: "Product 100\\%\\_\\A%" })
    assert_equal ["Red Apple"], names(field => { ilike: "product%" })
    assert_equal ["Red Apple"], names(field => { prefix: "Product 100%_\\" })
    assert_equal ["Red Apple"], names(field => /Product.*/)
    assert_empty names(field => { prefix: "Product') OR TRUE --" })
  end

  def test_deep_empty_and_null_arrays_remain_missing
    tinkick_test_products(:red_apple).update!(metadata: { tags: [[[nil, []]], []] })
    tinkick_test_products(:green_pear).update!(metadata: { tags: [[[false]]] })

    assert_equal ["Red Apple"], names("metadata.tags" => nil)
    assert_equal ["Red Apple"], names("metadata.tags" => { exists: false })
    assert_equal ["Green Pear"], names("metadata.tags" => { exists: true })
    assert_equal ["Green Pear"], names("metadata.tags" => false)
    tinkick_test_products(:green_pear).update!(metadata: { tags: [[[""]]] })
    assert_equal ["Green Pear"], names("metadata.tags" => { exists: true })
  end

  def test_root_arrays_flatten_without_descending_into_object_fields
    tinkick_test_products(:red_apple).update!(metadata: [[["red", nil]]])
    tinkick_test_products(:green_pear).update!(metadata: [[[{ color: "red" }]]])

    assert_equal ["Red Apple"], names(metadata: "red")
    assert_equal ["Green Pear"], names("metadata.color" => "red")
  end

  def test_recursive_equality_keeps_a_gin_candidate_predicate_and_warns_about_verification
    tinkick_test_products(:red_apple).update!(metadata: { tags: [[["red"]]] })
    output = StringIO.new
    original_logger = SearchProduct.logger
    SearchProduct.logger = Logger.new(output, level: Logger::WARN)

    relation = Tinkick::Filter.new(SearchProduct).apply(SearchProduct.all, "metadata.tags" => "red")
    assert_equal ["Red Apple"], relation.pluck(:name)
    SearchProduct.with_connection do |connection|
      connection.execute("SET LOCAL enable_seqscan = off")
      plan = connection.select_values("EXPLAIN #{relation.to_sql}").join("\n")
      assert_includes plan, "index_tinkick_test_products_on_metadata"
      assert_includes plan, "Index Cond"
    end
    assert_includes output.string, "recursive"
  ensure
    SearchProduct.logger = original_logger
  end

  private

  def names(conditions)
    Tinkick::Filter.new(SearchProduct).apply(SearchProduct.all, conditions).order(:name).pluck(:name)
  end
end
