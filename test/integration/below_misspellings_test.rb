# frozen_string_literal: true

require_relative "../integration_helper"

class BelowMisspellingsTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  setup do
    @exact = tinkick_test_products(:red_apple)
    @fuzzy = tinkick_test_products(:green_pear)
    @exact.update!(name: "abc", description: "An orchard journal")
    @fuzzy.update!(name: "abd", description: "A coastline atlas")
  end

  def test_exact_hits_at_threshold_keep_the_exact_pass
    result = search(below: 1)

    assert_equal([@exact.id], result.map(&:id))
    refute_predicate(result, :misspellings?)
    assert_equal(1, result.total_count)
  end

  def test_count_first_falls_back_and_reuses_the_policy_for_records_and_aggregations
    result = search(below: 2, aggs: [:name], limit: 1)

    assert_equal(2, result.total_count)
    assert_predicate(result, :misspellings?)
    assert_equal(1, result.size)
    assert_equal(%w[abc abd], result.aggs.fetch("name").fetch("buckets").map { |bucket| bucket.fetch("key") }.sort)
  end

  def test_aggregation_first_uses_original_filters_for_the_decision_even_with_smart_facets
    result = search(below: 1, where: { name: "abd" }, aggs: [:name])

    assert_equal(%w[abc abd], result.aggs.fetch("name").fetch("buckets").map { |bucket| bucket.fetch("key") }.sort)
    assert_predicate(result, :misspellings?)
    assert_equal([@fuzzy.id], result.map(&:id))
    assert_equal(1, result.total_count)
  end

  def test_exclusions_affect_threshold_but_page_offset_and_result_scope_do_not
    excluded = search(below: 1, exclude: "abc")
    assert_equal([@fuzzy.id], excluded.map(&:id))
    assert_predicate(excluded, :misspellings?)

    paged = search(below: 1, offset: 10, limit: 1)
    assert_empty(paged)
    refute_predicate(paged, :misspellings?)

    scoped = search(below: 1, scope_results: ->(relation) { relation.where(id: @fuzzy.id) })
    assert_empty(scoped)
    refute_predicate(scoped, :misspellings?)
    assert_equal(1, scoped.total_count)
  end

  def test_total_entries_override_does_not_control_the_fallback
    result = search(below: 2, total_entries: 50)

    assert_equal(50, result.total_count)
    assert_predicate(result, :misspellings?)
    assert_equal([@exact.id, @fuzzy.id].sort, result.map(&:id).sort)
  end

  def test_per_field_fallback_preserves_exact_fields_and_fuzzy_controls
    @fuzzy.update!(name: "Coastline", description: "abd")
    exact_only = search(below: 2, fields: [:name, :description], fuzzy_fields: [:name])
    assert_equal([@exact.id], exact_only.map(&:id))
    assert_predicate(exact_only, :misspellings?)

    enabled = search(below: 2, fields: [:name, :description], fuzzy_fields: [:description])
    assert_equal([@exact.id, @fuzzy.id].sort, enabled.map(&:id).sort)
    assert_predicate(enabled, :misspellings?)
  end

  def test_lazy_policy_uses_one_bounded_count_without_instantiating_records_and_warns_once
    Product.search("abc", fields: [:name], misspellings: false).total_count
    queries = []
    instantiations = []
    output = StringIO.new
    old_logger = Product.logger
    Product.logger = ActiveSupport::Logger.new(output)
    sql = ->(_name, _start, _finish, _id, payload) { queries << payload }
    records = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }
    ActiveSupport::Notifications.subscribed(records, "instantiation.active_record") do
      ActiveSupport::Notifications.subscribed(sql, "sql.active_record") do
        result = search(below: 2, offset: 10, aggs: [:name])
        assert_empty(queries)
        assert_predicate(result, :misspellings?)
        assert_predicate(result, :misspellings?)
        assert_equal(2, result.total_count)
        result.aggs
        assert_empty(instantiations)
      end
    end
    probes = queries.select { |payload| payload[:sql].include?("subquery_for_count") }
    assert_equal(1, probes.length)
    probe = probes.fetch(0)
    assert_match(/SELECT COUNT\(\*\) FROM \(SELECT 1 AS one.*LIMIT/m, probe[:sql])
    refute_includes(probe[:sql], "OFFSET")
    values = probe[:binds].map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
    assert_includes(values, 2)
    assert_equal(1, output.string.scan(/misspellings.*below.*bounded/i).length)
  ensure
    Product.logger = old_logger
  end

  def test_metadata_describes_enabled_pass_and_match_all_stays_nonfuzzy
    assert_predicate(Product.search("abc", fields: [:name], misspellings: true), :misspellings?)
    refute_predicate(Product.search("abc", fields: [:name], misspellings: false), :misspellings?)
    [:phrase, :exact].each do |mode|
      assert_predicate(search(below: 2, match: mode), :misspellings?)
      assert_equal([@exact.id], search(below: 2, match: mode).map(&:id))
    end
    assert_predicate(search(below: 2, fuzzy_fields: []), :misspellings?)
    refute_predicate(Product.search("*", fields: [:name], misspellings: { below: 10 }), :misspellings?)
  end

  def test_threshold_coercion_and_nonpositive_values_match_upstream
    [0, -2].each do |value|
      result = search(below: value)
      assert_equal([@exact.id], result.map(&:id))
      refute_predicate(result, :misspellings?)
    end
    ["2", 2.9, false, nil].each do |value|
      result = search(below: value)
      assert_equal(2, result.total_count)
      assert_predicate(result, :misspellings?)
    end
  end

  private

  def search(below:, fuzzy_fields: nil, **options)
    misspellings = { below: below }
    misspellings[:fields] = fuzzy_fields unless fuzzy_fields.nil?
    Product.search("abc", fields: [:name], misspellings: misspellings, **options)
  end
end
