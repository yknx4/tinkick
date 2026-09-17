# frozen_string_literal: true

require_relative "../integration_helper"

class RecencyBoostSearchTest < TinkickIntegrationTest
  class Product < ActiveRecord::Base
    self.table_name = "tinkick_test_cursor_values"
    tinkick searchable: [:name]
  end

  setup do
    @origin = Time.utc(2026, 9, 17)
    @records = [0, 7, 14].each_with_index.map do |days, index|
      Product.create!(name: ["mithril lantern forge", "mithril lantern archive", "mithril lantern history"].fetch(index),
        price: index + 1, ratio: 2, recorded_at: @origin - days * 86_400,
        recorded_on: @origin.to_date - days, code: "00000000-0000-0000-0000-000000000001")
    end
    Product.create!(name: "pottery kiln manual", price: 999, ratio: 999, recorded_at: @origin,
      recorded_on: @origin.to_date, code: "00000000-0000-0000-0000-000000000002")
  end

  def test_model_and_global_recency_queries_multiply_native_relevance_and_keep_matches
    baseline = scores(search)
    [search(boost_by_recency: { recorded_at: options }),
     Tinkick.search("mithril lantern", model: Product, fields: ["name^1"], misspellings: false,
       boost_by_recency: { recorded_at: options })].each do |page|
      assert_equal @records.map(&:id), page.map(&:id)
      page.with_score.each do |record, score|
        days = (@origin - record.recorded_at) / 86_400
        assert_in_epsilon baseline.fetch(record.id) * 0.5**((days / 7)**2), score, 0.000001
      end
      assert_equal 3, page.total_count
    end
  end

  def test_recency_composes_with_numeric_multipliers_and_conditional_sum_weights
    baseline = scores(search)
    page = search(boost_by_recency: { recorded_at: options.merge(factor: 3) },
      boost_by: { price: { modifier: "none" }, ratio: { boost_mode: "multiply" } },
      boost_where: { id: { value: @records.first.id, factor: 0.25 } })
    page.with_score.each do |record, score|
      days = (@origin - record.recorded_at) / 86_400
      sum = 3 * 0.5**((days / 7)**2) + record.price + (record.id == @records.first.id ? 0.25 : 0)

      assert_in_epsilon baseline.fetch(record.id) * sum * record.ratio, score, 0.000001
    end
  end

  def test_fluent_calls_merge_fields_replace_duplicates_and_preserve_the_original
    original = search(boost_by_recency: { recorded_at: options })
    changed = original.boost_by_recency(recorded_on: options.merge(function: :linear))
      .boost_by_recency(recorded_at: options.merge(function: :exp))
    expected = search(boost_by_recency: { recorded_at: options.merge(function: :exp), recorded_on: options.merge(function: :linear) })

    assert_equal scores(expected), scores(changed)
    assert_equal scores(search), scores(original.except(:boost_by_recency))
    assert_equal scores(search), scores(original.only(:fields, :misspellings))
    refute_equal scores(search), scores(original)
    assert_raises(Tinkick::Error) { original.boost_by_recency!(recorded_at: options) }
    refute original.boost_by_recency(recorded_at: options).loaded?
  end

  def test_raw_countless_pages_cache_weighted_hits_and_highlights_without_counting
    page = search(boost_by_recency: { recorded_at: options }, load: false, select: [:name],
      highlight: true, countless: true, limit: 2)
    statements = capture_queries do
      assert_equal @records.first(2).map { |record| record.id.to_s }, page.hits.map { |hit| hit.fetch("_id") }
      assert_equal page.hits.map { |hit| hit.fetch("_score") }, page.with_score.map { |_record, score| score }
      assert_includes page.highlights.first.fetch(:name), "<em>mithril</em>"
      assert page.has_next_page?
    end

    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_empty capture_queries {
                   page.hits
                   page.highlights
                   page.with_score.to_a }
  end

  def test_column_cursors_keep_recency_scores_without_relevance_cursor_keys
    options = { boost_by_recency: { recorded_at: self.options }, keyset: true, order: :id, limit: 1 }
    first = search(**options)
    second = search(**options, after: first.next_cursor)

    assert_equal @records.first.id, first.first.id
    assert_equal @records.fetch(1).id, second.first.id
    assert_in_epsilon scores(search(boost_by_recency: options.fetch(:boost_by_recency))).fetch(second.first.id),
      second.with_score.first.last, 0.000001
  end

  def test_counts_and_aggregations_do_not_compile_score_only_field_requirements
    page = search(boost_by_recency: { missing_date: options }, aggs: { price: { ranges: [{ from: 0 }] } })

    assert_equal 3, page.total_count
    assert_equal 3, page.aggs.fetch("price").fetch("buckets").first.fetch("doc_count")
    assert_raises(Tinkick::MissingFieldError) { page.to_a }
  end

  def test_zero_weights_follow_single_function_and_multiple_function_sum_behavior
    zero = options.merge(factor: 0)
    baseline = scores(search)

    assert_equal [0.0], scores(search(boost_by_recency: { recorded_at: zero })).values.uniq
    assert_equal baseline, scores(search(boost_by_recency: { recorded_at: zero, recorded_on: zero }))
    assert_equal baseline, scores(search(boost_by_recency: { recorded_at: zero },
      boost_where: { id: { value: @records.first.id, factor: 0 } }))
    assert_equal [0.0], scores(search(boost_by_recency: { recorded_at: zero },
      boost_by: { price: { factor: 0, modifier: "none" } })).values.uniq
  end

  def test_disabled_recency_options_keep_native_sql_and_do_not_warn
    previous = Product.logger
    output = StringIO.new
    Product.logger = Logger.new(output)
    baseline = scores(search)
    [nil, false, {}].each do |value|
      statements = capture_queries { assert_equal baseline, scores(search(boost_by_recency: value)) }
      refute statements.any? { |sql| sql.include?("LEAST(") }
    end
    refute_match(/recency/i, output.string)
  ensure
    Product.logger = previous
  end

  private

  def options
    { origin: @origin, scale: "7d", decay: 0.5 }
  end

  def search(**options)
    Product.search("mithril lantern", fields: ["name^1"], misspellings: false, **options)
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
