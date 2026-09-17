# frozen_string_literal: true

require_relative "../integration_helper"

class NumericBoostSearchTest < TinkickIntegrationTest
  class Product < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
    tinkick searchable: [:name]
  end

  def test_model_and_global_keywords_rank_match_all_results_by_numeric_values
    low, middle, high = products
    page = Product.search("*", boost_by: [:price])

    assert_equal [high.id, middle.id, low.id], page.map(&:id)
    page.with_score.each { |record, score| assert_in_delta Math.log(record.price + 2), score, 0.000001 }
    global = Tinkick.search("*", model: Product, boost_by: { price: { factor: 0.5, modifier: "none" } })

    assert_equal [high.id, middle.id, low.id], global.map(&:id)
    assert_equal [50.0, 5.0, 0.5], global.with_score.map { |_record, score| score }
  end

  def test_native_relevance_and_field_weights_are_multiplied_by_numeric_functions
    products
    baseline = scores(search(fields: ["name^1"]))
    weighted = scores(search(fields: ["name^3"], boost_by: { price: {} }))

    assert_equal baseline.keys.sort, weighted.keys.sort
    Product.find_each do |record|
      assert_in_delta baseline.fetch(record.id) * 3 * Math.log(record.price + 2), weighted.fetch(record.id), 0.00001
    end
  end

  def test_sql_field_scores_and_large_native_weights_compose_with_numeric_functions
    low, = products
    exact = Product.search("ruby compass", fields: [{ "name^2.5" => :exact }], misspellings: false,
      boost_by: { price: { factor: 4, modifier: "none" } })

    assert_equal [[low.id, 10.0]], exact.with_score.map { |record, score| [record.id, score] }
    baseline = scores(search(fields: ["name^20000"]))
    boosted = scores(search(fields: ["name^20000"], boost_by: { price: { boost_mode: "multiply" } }))
    Product.find_each do |record|
      assert_in_delta baseline.fetch(record.id) * record.price, boosted.fetch(record.id), 0.001
    end
  end

  def test_fluent_scalar_array_and_hash_options_merge_without_mutating_the_original
    products
    original = Product.search("*", boost_by: { price: { modifier: "none" } })
    combined = original.boost_by(:ratio).boost_by([:id]).boost_by(ratio: { factor: 2, boost_mode: "multiply" })
    expected = Product.all.to_h { |record| [record.id, (record.price + Math.log(record.id + 2)) * record.ratio * 2] }

    scores(combined).each { |id, score| assert_in_delta expected.fetch(id), score, 0.00001 }
    assert_equal [100.0, 10.0, 1.0], original.with_score.map { |_record, score| score }
    assert_raises(Tinkick::Error) { original.boost_by!(:ratio) }
    refute original.boost_by(:ratio).loaded?
  end

  def test_only_and_except_remove_numeric_boosts_without_changing_the_original
    products
    original = search(boost_by: { price: { modifier: "none" } })
    baseline = scores(search)

    assert_equal baseline, scores(original.except(:boost_by))
    assert_equal baseline, scores(original.only(:fields, :misspellings))
    refute_equal baseline, scores(original)
  end

  def test_raw_hits_projection_highlighting_and_column_cursors_keep_weighted_scores
    low, middle, = products
    options = { boost_by: { price: { modifier: "none" } }, fields: ["name^1"],
                load: false, select: [:name], highlight: true, keyset: true, order: :id, limit: 1 }
    page = search(**options)
    statements = capture_queries do
      hit = page.hits.first

      assert_equal low.id.to_s, hit.fetch("_id")
      assert_equal ["name"], hit.fetch("_source").keys
      assert_equal hit.fetch("_score"), page.with_score.first.last
      assert_includes page.highlights.first.fetch(:name), "<em>ruby</em>"
      assert page.has_next_page?
      refute_nil page.next_cursor
    end

    refute statements.any? { |statement| statement.fetch(:sql).match?(/COUNT\(/i) }
    assert_equal middle.id.to_s, search(**options, after: page.next_cursor).hits.first.fetch("_id")
    assert_equal 3, page.total_count
  end

  def test_countless_relevance_returns_the_highest_numeric_scores_without_counting
    _, middle, high = products
    page = search(boost_by: { price: { modifier: "none" } }, countless: true, limit: 2)
    statements = capture_queries do
      assert_equal [high.id, middle.id], page.map(&:id)
      assert page.has_next_page?
      assert_equal 2, page.next_page
    end

    refute statements.any? { |statement| statement.fetch(:sql).match?(/COUNT\(/i) }
    assert_equal 3, page.total_count
  end

  def test_count_and_aggregations_do_not_evaluate_numeric_score_functions
    low, middle, high = products
    low.update!(price: -10)
    page = search(boost_by: [:price], aggs: { price: { ranges: [{ to: 0 }, { from: 0 }] } })

    assert_equal 3, page.total_count
    assert_equal [1, 2], page.aggs.fetch("price").fetch("buckets").map { |bucket| bucket.fetch("doc_count") }
    filtered = search(boost_by: [:price], where: { id: [middle.id, high.id] })

    assert_equal [high.id, middle.id], filtered.map(&:id)
  end

  def test_zero_numeric_scores_preserve_matches_and_exclusions_still_apply
    low, middle, = products
    page = search(boost_by: { price: { factor: 0, modifier: "none" } }, exclude: "south", order: :id)

    assert_equal [[low.id, 0.0], [middle.id, 0.0]], page.with_score.map { |record, score| [record.id, score] }
    assert_equal 2, page.total_count
  end

  def test_numeric_boost_warns_once_for_cached_pages_and_disabled_options_leave_native_sql_unchanged
    products
    output = StringIO.new
    previous = Product.logger
    Product.logger = Logger.new(output)
    page = search(boost_by: [:price])
    page.to_a
    page.hits
    page.with_score.to_a

    assert_equal 1, output.string.scan(/numeric boost_by scoring/).length
    assert_includes output.string, "sort"
    output.truncate(0)
    output.rewind
    statements = capture_queries { search(boost_by: false).to_a }

    refute_includes output.string, "numeric boost_by scoring"
    refute statements.any? { |statement| statement.fetch(:sql).include?("LEAST(") }
  ensure
    Product.logger = previous
  end

  private

  def products
    [["ruby compass", 1, 2], ["ruby compass north", 10, 3], ["ruby compass south", 100, 4]].map do |name, price, ratio|
      Product.create!(name: name, price: price, ratio: ratio,
        code: "00000000-0000-0000-0000-000000000001", recorded_on: "2026-09-17", recorded_at: "2026-09-17T12:00:00Z")
    end
  end

  def search(**options)
    Product.search("ruby compass", fields: ["name^1"], misspellings: false, **options)
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
