# frozen_string_literal: true

require_relative "../integration_helper"

class LegacyBoostTest < TinkickIntegrationTest
  class Product < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
    tinkick searchable: [:name]
  end

  def test_model_and_global_alias_use_default_numeric_formula_without_changing_matches
    records = products
    baseline = scores(search)
    [search(boost: :price), Tinkick.search("mithril lantern", model: Product,
      fields: ["name^1"], misspellings: false, boost: "price")].each do |page|
      assert_equal records.map(&:id).sort, page.map(&:id).sort
      page.with_score.each do |record, score|
        assert_in_epsilon baseline.fetch(record.id) * Math.log(record.price + 2), score, 0.000001
      end
      assert_equal 2, page.total_count
    end
  end

  def test_alias_replaces_same_field_sum_but_keeps_multiply_function
    records = products
    baseline = scores(search)
    options = { boost: :price, boost_where: { id: { value: records.first.id, factor: 0.25 } } }
    replaced = scores(search(**options, boost_by: { price: { factor: 99, modifier: "none" }, ratio: {} }))
    multiplied = scores(search(**options, boost_by: { price: { boost_mode: "multiply" } }))
    records.each do |record|
      conditional = record.id == records.first.id ? 0.25 : 0
      sum = Math.log(record.price + 2) + conditional

      assert_in_epsilon baseline.fetch(record.id) * (sum + Math.log(record.ratio + 2)), replaced.fetch(record.id), 0.000001
      assert_in_epsilon baseline.fetch(record.id) * sum * record.price, multiplied.fetch(record.id), 0.000001
    end
  end

  def test_fluent_alias_replaces_its_field_and_keeps_other_options_and_original
    products
    original = search(boost: :price)
    changed = original.boost(:ratio)

    assert_equal scores(search(boost_by: [:ratio])), scores(changed)
    assert_equal scores(search(boost_by: [:price])), scores(original)
    assert_raises(Tinkick::Error) { original.boost!(:ratio) }
    refute original.boost(:ratio).loaded?
  end

  def test_only_and_except_remove_alias_independently_of_numeric_boosts
    products
    page = search(boost: :price, boost_by: [:ratio])

    assert_equal scores(search(boost_by: [:ratio])), scores(page.except(:boost))
    assert_equal scores(search(boost: :price)), scores(page.except(:boost_by))
    assert_equal scores(search(boost: :price)), scores(page.only(:fields, :misspellings, :boost))
  end

  def test_false_and_nil_aliases_preserve_native_scores
    products
    baseline = scores(search)

    assert_equal baseline, scores(search(boost: false))
    assert_equal baseline, scores(search.boost(nil))
    assert_equal baseline, scores(search(boost: :price).boost(false))
  end

  private

  def products
    rows = [["mithril lantern forge", 1, 4], ["mithril lantern archive", 10, 2], ["pottery kiln guide", 1000, 1000]]
    rows.map do |name, price, ratio|
      Product.create!(name: name, price: price, ratio: ratio,
        code: "00000000-0000-0000-0000-000000000001", recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z")
    end.first(2)
  end

  def search(**options)
    Product.search("mithril lantern", fields: ["name^1"], misspellings: false, **options)
  end

  def scores(page)
    page.with_score.to_h { |record, score| [record.id, score] }
  end
end
