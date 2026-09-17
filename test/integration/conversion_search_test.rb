# frozen_string_literal: true

require_relative "../integration_helper"

class ConversionSearchTest < TinkickIntegrationTest
  class Legacy < SearchProduct
    tinkick searchable: [:name], conversions: :metadata
  end

  class Modern < SearchProduct
    tinkick searchable: [:name], conversions_v2: :conversion_counts
  end

  class Both < SearchProduct
    tinkick searchable: [:name], conversions: :metadata, conversions_v2: :conversion_counts
  end

  setup do
    SearchProduct.delete_all
    @records = [
      ["mithril mithril mithril", { "mithril" => 2, "Moria" => 400 }, { "mithril" => 0 }],
      ["mithril lantern carried on the long journey through Moria", { "mithril" => 100 }, { "mithril" => 0 }],
      ["mithril tools", {}, { "mithril" => 500, "forge" => 600 }],
    ].map do |name, legacy, modern|
      SearchProduct.create!(name: name, metadata: legacy, conversion_counts: modern)
    end
    @unrelated = SearchProduct.create!(name: "Rivendell songs about trees", metadata: { "mithril" => 100_000 })
    @baseline = scores(search(conversions: false, conversions_v2: false))
  end

  def test_legacy_counts_change_ranking_without_expanding_membership
    page = search
    assert_equal @records.fetch(1).id, page.first.id
    assert_equal @records.map(&:id).sort, page.map(&:id).sort
    refute_includes page.map(&:id), @unrelated.id
    assert_equal 3, page.total_count
    assert_contributions page, [2, 100, 0]

    global = Tinkick.search("mithril", model: Legacy, fields: ["name^1"], misspellings: false)
    assert_equal scores(page), scores(global)
  end

  def test_v2_defaults_and_explicit_factor_use_native_additive_scoring
    assert_equal @records.last.id, search(model: Modern).first.id
    assert_contributions search(model: Modern), [0, 0, 500]
    assert_contributions search(model: Modern, conversions_v2: { factor: 0.25 }), [0, 0, 125]
    assert_contributions search(model: Modern, conversions_v2: { factor: 0 }), [0, 0, 0]
    assert_contributions search(model: Modern, conversions_v2: :metadata), [2, 100, 0]
  end

  def test_both_declarations_keep_legacy_default_until_v2_is_requested
    assert_contributions search(model: Both), [2, 100, 0]
    assert_equal @baseline, scores(search(model: Both, conversions: false))
    assert_contributions search(model: Both, conversions_v2: true), [2, 100, 500]
    assert_contributions search(model: Both, conversions: false, conversions_v2: {}), [0, 0, 500]
    assert_equal @baseline, scores(search(model: Modern, conversions_v2: false))
  end

  def test_legacy_alias_and_field_selection_preserve_caller_controls
    assert_equal @baseline, scores(search(conversions: :metadata, conversions_v1: false))
    assert_contributions search(conversions: false, conversions_v1: nil), [2, 100, 0]
    assert_equal @baseline, scores(search(conversions: []))
    assert_contributions search(conversions: [:metadata, "metadata", :conversion_counts]), [2, 100, 500]
    assert_contributions search(conversions: "conversion_counts"), [0, 0, 500]
  end

  def test_term_precedence_is_whole_key_lookup_independent_of_lexical_query
    assert_contributions search(conversions_term: "Moria"), [400, 0, 0]
    assert_contributions search(model: Both, conversions_term: "Moria",
      conversions_v2: { term: "forge", factor: 0.5 }), [400, 0, 300]
    assert_contributions search(model: Modern, conversions_term: "forge",
      conversions_v2: { field: true, term: false }), [0, 0, 600]
    assert_contributions search(conversions_term: :Moria), [400, 0, 0]
    @records.last.update!(conversion_counts: { "123" => 25 })
    assert_contributions search(model: Modern, conversions_v2: { term: 123 }), [0, 0, 25]
  end

  def test_conversions_are_added_before_other_boost_multipliers
    page = search(boost_where: { id: { value: @records.fetch(1).id, factor: 3 } })
    page.with_score.each do |record, score|
      count = [2, 100, 0].fetch(@records.index { |item| item.id == record.id })
      multiplier = record.id == @records.fetch(1).id ? 3 : 1
      assert_in_epsilon (@baseline.fetch(record.id) + count) * multiplier, score, 0.000001
    end
  end

  def test_match_all_bypasses_conversion_columns_and_terms
    page = Legacy.search("*", conversions: :missing_column, conversions_term: "mithril", misspellings: false)
    assert_equal 4, page.size
    assert_equal [1.0], page.with_score.map { |_record, score| score }.uniq
  end

  def test_counts_and_aggregations_do_not_compile_score_only_columns
    page = search(conversions: :missing_column, aggs: [:name])
    assert_equal 3, page.total_count
    assert_equal 3, page.aggs.fetch("name").fetch("buckets").sum { |bucket| bucket.fetch("doc_count") }
    assert_raises(Tinkick::MissingFieldError) { page.to_a }
  end

  def test_invalid_selectors_are_rejected_instead_of_silently_disabled
    [{ conversions: true }, { conversions: [1] }, { conversions_v2: [:metadata] },
     { conversions_v2: { field: false } }, { conversions_v2: { unknown: 1 } }].each do |options|
      assert_raises(ArgumentError) { search(**options).to_a }
    end
  end

  private

  def search(model: Legacy, **options)
    model.search("mithril", fields: ["name^1"], misspellings: false, **options)
  end

  def scores(page)
    page.with_score.to_h { |record, score| [record.id, score] }
  end

  def assert_contributions(page, counts)
    assert_equal @records.map(&:id).sort, page.map(&:id).sort
    page.with_score.each do |record, score|
      count = counts.fetch(@records.index { |item| item.id == record.id })
      assert_in_epsilon @baseline.fetch(record.id) + count, score, 0.000001
    end
  end
end
