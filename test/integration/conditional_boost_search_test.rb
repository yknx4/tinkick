# frozen_string_literal: true

require_relative "../integration_helper"

class ConditionalBoostSearchTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  setup do
    @forge = tinkick_test_products(:red_apple)
    @archive = tinkick_test_products(:green_pear)
    @forge.update!(name: "Mithril lantern forge", ratings: [2], metadata: { place: "Moria", rare: true })
    @archive.update!(name: "Mithril lantern archive", ratings: [3], metadata: { place: "Rivendell", rare: false })
    Product.create!(name: "Lantern guide", ratings: [4], metadata: { rare: true })
    @unrelated = Product.create!(name: "Pottery kiln manual", ratings: [99], metadata: { rare: true })
  end

  def test_default_conditional_boost_changes_scores_without_admitting_unrelated_documents
    baseline = scores(search)
    page = search(boost_where: { "metadata.rare" => true })

    assert_equal [@forge.id, @archive.id], page.map(&:id)
    assert_in_delta baseline.fetch(@forge.id) * 1000, scores(page).fetch(@forge.id), 0.00001
    assert_equal baseline.fetch(@archive.id), scores(page).fetch(@archive.id)
    refute_includes page.map(&:id), @unrelated.id
    assert_equal 2, page.total_count
  end

  def test_global_search_combines_conditional_demotion_with_numeric_boosts
    baseline = scores(search)
    page = Tinkick.search("mithril lantern", model: Product, fields: ["name^1"], misspellings: false,
      boost_where: { id: { value: @forge.id, factor: 0.5 } }, boost_by: { ratings: { modifier: "none" } })

    assert_equal [@archive.id, @forge.id], page.map(&:id)
    assert_in_delta baseline.fetch(@forge.id) * 2.5, scores(page).fetch(@forge.id), 0.00001
    assert_in_delta baseline.fetch(@archive.id) * 3, scores(page).fetch(@archive.id), 0.00001
  end

  def test_fluent_boosts_merge_by_field_and_leave_the_original_unchanged
    baseline = scores(search)
    original = search.boost_where("metadata.place" => "Moria")
    changed = original.boost_where("metadata.place" => "Rivendell").boost_where(id: { value: @forge.id, factor: 2 })

    assert_equal [@archive.id, @forge.id], changed.map(&:id)
    assert_in_delta baseline.fetch(@forge.id) * 2, scores(changed).fetch(@forge.id), 0.00001
    assert_in_delta baseline.fetch(@archive.id) * 1000, scores(changed).fetch(@archive.id), 0.00001
    assert_equal [@forge.id, @archive.id], original.map(&:id)
    assert_raises(Tinkick::Error) { original.boost_where!(id: @forge.id) }
    refute original.boost_where(id: @forge.id).loaded?
  end

  def test_only_and_except_restore_unboosted_scoring
    baseline = scores(search)
    original = search(boost_where: { id: @forge.id })

    assert_equal baseline, scores(original.except(:boost_where))
    assert_equal baseline, scores(original.only(:fields, :misspellings))
    refute_equal baseline, scores(original)
  end

  def test_counts_and_aggregations_do_not_compile_unused_scoring_conditions
    page = search(boost_where: { absent_score_field: { value: 1, factor: 2 } }, aggs: { name: { limit: 10 } })

    assert_equal 2, page.total_count
    assert_equal [1, 1], page.aggs.fetch("name").fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    assert_raises(Tinkick::MissingFieldError) { page.to_a }
  end

  def test_raw_highlighted_countless_pages_keep_conditional_scores_without_counting
    baseline = scores(search)
    page = search(boost_where: { id: @forge.id }, load: false, select: [:name], highlight: true,
      countless: true, limit: 1)
    statements = capture_queries do
      assert_equal @forge.id.to_s, page.hits.first.fetch("_id")
      assert_equal ["name"], page.hits.first.fetch("_source").keys
      assert_in_delta baseline.fetch(@forge.id) * 1000, page.hits.first.fetch("_score"), 0.00001
      assert_includes page.highlights.first.fetch(:name), "<em>Mithril</em>"
      assert page.has_next_page?
    end

    refute statements.any? { |statement| statement.fetch(:sql).match?(/COUNT\(/i) }
    assert_empty capture_queries {
                   page.hits
                   page.highlights }
  end

  def test_column_cursors_keep_their_order_and_preserve_conditional_scores
    baseline = scores(search)
    ordered = [@forge.id, @archive.id].sort
    options = { boost_where: { id: @forge.id }, order: :id, keyset: true, limit: 1 }
    first = search(**options)

    assert_equal [ordered.first], first.map(&:id)
    assert first.has_next_page?
    second = search(**options, after: first.next_cursor)
    assert_equal [ordered.last], second.map(&:id)
    refute second.has_next_page?
    [first, second].each do |page|
      record, score = page.with_score.first
      factor = record.id == @forge.id ? 1000 : 1
      assert_in_delta baseline.fetch(record.id) * factor, score, 0.00001
    end
  end

  def test_disabled_and_zero_boosts_leave_native_scoring_sql_unchanged
    baseline = scores(search)
    [nil, false, {}, { id: { value: @forge.id, factor: 0 } }].each do |specification|
      statements = capture_queries { assert_equal baseline, scores(search(boost_where: specification)) }

      refute statements.any? { |statement| statement.fetch(:sql).include?("LEAST(") }
    end
  end

  def test_actual_plan_retains_tin_matching_and_sorts_conditional_scores
    statements = capture_queries do
      assert_equal [@forge.id, @archive.id], search(boost_where: { id: @forge.id }).map(&:id)
    end
    statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_score") }
    plan = Product.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick Conditional Boost Explain", statement.fetch(:binds))

    assert_includes plan, "Text Search Scan"
    assert_includes plan, "index_tinkick_test_products_on_name"
    assert_includes plan, "Sort"
  end

  private

  def search(**options)
    Product.tinkick_search("mithril lantern", fields: ["name^1"], misspellings: false, **options)
  end

  def scores(relation)
    relation.with_score.to_h { |record, score| [record.id, score] }
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
