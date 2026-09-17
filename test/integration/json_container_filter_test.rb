# frozen_string_literal: true

require_relative "../integration_helper"

class JsonContainerFilterTest < TinkickIntegrationTest
  def test_container_nil_and_exists_follow_non_null_descendant_values
    tinkick_test_products(:red_apple).update!(metadata: { details: { shipping: { domestic: false } } })
    tinkick_test_products(:green_pear).update!(metadata: { details: { shipping: { domestic: nil } } })

    assert_equal ["Red Apple"], names("metadata.details" => { exists: true })
    assert_equal ["Green Pear"], names("metadata.details" => { exists: false })
    assert_equal ["Green Pear"], names("metadata.details" => nil)
    assert_equal ["Red Apple"], names("metadata.details" => { not: nil })
    assert_equal ["Green Pear"], names(_not: { "metadata.details" => { exists: true } })
    assert_equal ["Green Pear"], names("metadata.details" => [nil])
  end

  def test_empty_and_null_only_containers_have_no_indexed_descendants
    tinkick_test_products(:red_apple).update!(metadata: { details: { year: 2026 } })
    absent_values = [{}, { value: nil }, { nested: {} }, { nested: [nil, {}, []] },
      { nested: [[[{ empty: { missing: [nil] } }]]] }, [], nil]
    absent_values.each do |value|
      tinkick_test_products(:green_pear).update!(metadata: { details: value })

      assert_equal ["Green Pear"], names("metadata.details" => nil), value.inspect
      assert_equal ["Red Apple"], names("metadata.details" => { exists: true }), value.inspect
    end
  end

  def test_false_zero_and_empty_string_descendants_are_present_at_the_root
    tinkick_test_products(:green_pear).update!(metadata: { nested: [nil, {}] })
    [false, 0, ""].each do |value|
      tinkick_test_products(:red_apple).update!(metadata: { nested: [[[{ "quoted\" key" => value }]]] })

      assert_equal ["Red Apple"], names(metadata: { exists: true }), value.inspect
      assert_equal ["Green Pear"], names(metadata: nil), value.inspect
    end
  end

  def test_only_existence_checks_descend_into_final_object_members
    tinkick_test_products(:red_apple).update!(metadata: { details: { amount: 5, label: "red" } })
    tinkick_test_products(:green_pear).update!(metadata: { wrong: { details: { amount: 5, label: "red" } } })

    assert_equal ["Red Apple"], names("metadata.details" => { exists: true })
    assert_equal ["Green Pear"], names("metadata.details" => nil)
    assert_empty names("metadata.details" => "red")
    assert_empty names("metadata.details" => 3..7)
    assert_empty names("metadata.details" => { prefix: "red" })
  end

  def test_object_array_containers_preserve_dotted_paths_and_tin_scope
    tinkick_test_products(:red_apple).update!(metadata: [[[{ variants: [[[{ details: { label: "red" } }]]] }]]])
    tinkick_test_products(:green_pear).update!(metadata: { variants: [[[{ details: {} }]]],
      wrong: { variants: [{ details: { label: "green" } }] } })

    assert_equal ["Red Apple"], names("metadata.variants.details" => { exists: true })
    assert_equal ["Green Pear"], names("metadata.variants.details" => nil)
    assert_empty Tinkick::Relation.new(SearchProduct, "pear", fields: [:name], misspellings: false,
      where: { "metadata.variants.details" => { exists: true } }).to_a
  end

  private

  def names(conditions)
    Tinkick::Filter.new(SearchProduct).apply(SearchProduct.all, conditions).order(:name).pluck(:name)
  end
end
