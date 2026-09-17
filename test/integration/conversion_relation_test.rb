# frozen_string_literal: true

require_relative "../integration_helper"

class ConversionRelationTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name], conversions: :metadata, conversions_v2: :conversion_counts
  end

  setup do
    @forge = tinkick_test_products(:red_apple)
    @archive = tinkick_test_products(:green_pear)
    @forge.update!(name: "mithril forge map", metadata: { "mithril" => 20 }, conversion_counts: { "mithril" => 3 })
    @archive.update!(name: "mithril archive record", metadata: { "mithril" => 2, "Moria" => 40 }, conversion_counts: { "mithril" => 100 })
  end

  def test_fluent_controls_clone_and_v2_hashes_replace
    original = search
    changed = original.conversions(false).conversions_v2(term: "Moria", factor: 4)
      .conversions_v2(field: :metadata)
    assert_equal scores(search(conversions: false, conversions_v2: { field: :metadata })), scores(changed)
    assert_equal scores(search), scores(original)
    assert_equal scores(search(conversions: :conversion_counts)), scores(search.conversions_v1(:conversion_counts))
    assert_equal scores(search(conversions_term: "Moria")), scores(search.conversions_term("Moria"))
  end

  def test_bang_methods_return_self_and_reject_loaded_mutation
    { conversions: false, conversions_v1: false, conversions_v2: true, conversions_term: "Moria" }.each do |method, value|
      page = search
      assert_same page, page.public_send("#{method}!", value)
      expected = search(**{ method => value })
      assert_equal scores(expected), scores(page)
      assert_raises(Tinkick::Error) { page.public_send("#{method}!", value) }
      refute page.public_send(method, value).loaded?
      assert_raises(ArgumentError) { page.public_send(method) }
    end
  end

  def test_only_and_except_restore_declared_conversion_defaults
    changed = search.conversions(false).conversions_v2(true).conversions_term("Moria")
    assert_equal scores(search), scores(changed.only(:fields, :misspellings))
    assert_equal scores(search), scores(changed.except(:conversions, :conversions_v2, :conversions_term))
    assert_equal scores(search(conversions: false, conversions_v2: true)),
      scores(changed.except(:conversions_term))
  end

  def test_raw_countless_results_keep_scores_and_highlights_without_counting
    page = search.conversions(false).conversions_v2(true).load(false).select(:name).countless.limit(1).highlight
    statements = capture_queries do
      assert_equal [@archive.id.to_s], page.hits.map { |hit| hit.fetch("_id") }
      assert_in_epsilon scores(search(conversions: false, conversions_v2: true)).fetch(@archive.id), page.hits.first.fetch("_score"), 0.000001
      assert_includes page.highlights.first.fetch(:name), "<em>mithril</em>"
      assert page.has_next_page?
    end
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_empty capture_queries {
                   page.hits
                   page.highlights
                   page.with_score.to_a }
  end

  def test_column_keyset_cursors_preserve_conversion_scores
    options = { keyset: true, order: :id, limit: 1, conversions_v2: true }
    first = search(**options)
    second = search(**options, after: first.next_cursor)
    assert_equal [@forge.id, @archive.id].sort, [first.first.id, second.first.id]
    expected = scores(search(conversions_v2: true))
    [first, second].each do |page|
      page.with_score.each { |record, score| assert_in_epsilon expected.fetch(record.id), score, 0.000001 }
    end
    refute second.has_next_page?
  end

  private

  def search(**options)
    Product.search("mithril", misspellings: false, **options)
  end

  def scores(page)
    page.with_score.to_h { |record, score| [record.id, score] }
  end

  def capture_queries
    statements = []
    callback = ->(*arguments) { statements << arguments.last.fetch(:sql) unless arguments.last[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
