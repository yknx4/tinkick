# frozen_string_literal: true

require_relative "../integration_helper"

class StiAggregationsTest < TinkickIntegrationTest
  class Creature < ActiveRecord::Base
    self.table_name = "tinkick_test_creatures"
    tinkick searchable: [:name]
  end

  class Dwarf < Creature; end
  class Miner < Dwarf; end
  class Elf < Creature; end

  setup do
    @parent = Creature.create!(name: "mithril archive", category: "parent", amount: 100, ratings: [100], recorded_at: Time.utc(2026, 9, 1))
    @child = Dwarf.create!(name: "mithril forge", category: "forge", amount: 2, ratings: [2, 3], recorded_at: Time.utc(2026, 9, 2))
    @grandchild = Miner.create!(name: "mithril mine", category: "mine", amount: 6, ratings: [6], recorded_at: Time.utc(2026, 9, 4))
    @sibling = Elf.create!(name: "mithril poem", category: "sibling", amount: 200, ratings: [200], recorded_at: Time.utc(2026, 9, 6))
    Miner.create!(name: "coal tunnel", category: "unmatched", amount: 500, ratings: [500], recorded_at: Time.utc(2026, 9, 7))
  end

  def test_native_sti_search_and_counts_preserve_child_and_descendant_scope
    { Creature => [@parent, @child, @grandchild, @sibling], Dwarf => [@child, @grandchild], Miner => [@grandchild] }.each do |model, expected|
      page = search(model)
      assert_equal expected.map(&:id).sort, page.map(&:id).sort
      assert_equal expected.length, page.total_count
      assert_equal expected.map(&:class).sort_by(&:name), page.map(&:class).sort_by(&:name)
      assert_equal expected.map(&:id).sort, search(model, load: false).map(&:id).sort
    end
  end

  def test_terms_keep_parent_and_sibling_rows_out_of_child_aggregates
    assert_equal({ "forge" => 1, "mine" => 1 }, buckets(search(Dwarf, aggs: [:category]), :category))
    assert_equal({ "mine" => 1 }, buckets(search(Miner, aggs: [:category]), :category))
    assert_equal 4, buckets(search(Creature, aggs: [:category]), :category).values.sum
  end

  def test_zero_count_dictionary_keeps_the_native_child_scope
    page = search(Dwarf, aggs: { category: { min_doc_count: 0 } })

    assert_equal({ "forge" => 1, "mine" => 1, "unmatched" => 0 }, buckets(page, :category))
  end

  def test_scalar_and_array_metrics_use_only_matching_descendants
    page = search(Dwarf, aggs: { total: { sum: { field: :amount } },
                                average: { avg: { field: :amount } }, ratings: { sum: { field: :ratings } } })

    assert_equal 8.0, page.aggs.fetch("total").fetch("value")
    assert_equal 4.0, page.aggs.fetch("average").fetch("value")
    assert_equal 11.0, page.aggs.fetch("ratings").fetch("value")
    assert_equal 6.0, search(Miner, aggs: { amount: { sum: {} } }).aggs.fetch("amount").fetch("value")
  end

  def test_numeric_and_date_ranges_preserve_the_inner_sti_filter
    page = search(Dwarf, aggs: { amount: { ranges: [{ key: "low", to: 5 }, { key: "high", from: 5 }] },
                                recorded_at: { date_ranges: [{ key: "early", to: Time.utc(2026, 9, 3) },
                                                             { key: "late", from: Time.utc(2026, 9, 3) }] } })

    assert_equal({ "low" => 1, "high" => 1 }, buckets(page, :amount))
    assert_equal({ "early" => 1, "late" => 1 }, buckets(page, :recorded_at))
  end

  def test_numeric_histograms_preserve_the_inner_sti_filter
    page = search(Dwarf, aggs: { amount: { histogram: { interval: 2 } } })

    assert_equal({ 2.0 => 1, 4.0 => 0, 6.0 => 1 }, buckets(page, :amount))
  end

  def test_date_histograms_and_bound_queries_preserve_the_inner_sti_filter
    [0, 1].each do |minimum|
      settings = { calendar_interval: "day", min_doc_count: minimum,
                   extended_bounds: { min: Time.utc(2026, 9, 2), max: Time.utc(2026, 9, 4) } }
      page = search(Dwarf, aggs: { recorded_at: { date_histogram: settings } })
      expected = { Time.utc(2026, 9, 2).to_i * 1_000 => 1, Time.utc(2026, 9, 4).to_i * 1_000 => 1 }
      expected[Time.utc(2026, 9, 3).to_i * 1_000] = 0 if minimum.zero?

      assert_equal expected, buckets(page, :recorded_at)
    end
  end

  private

  def search(model, **options)
    model.search("mithril", misspellings: false, **options)
  end

  def buckets(page, field)
    page.aggs.fetch(field.to_s).fetch("buckets").to_h { |bucket| [bucket.fetch("key"), bucket.fetch("doc_count")] }
  end
end
