# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class SqlFieldBoostTest < ActionDispatch::IntegrationTest
  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  def test_exact_field_weights_reverse_ranking_and_add_for_records_matching_both_fields
    title_hit, body_hit, both = boost_documents
    title_first = search("sunforge", fields: [{ "title^12.5" => :exact }, { body: :exact }])
    body_first = search("sunforge", fields: [{ title: :exact }, { "body^12.5" => :exact }])

    assert_equal [both.id, title_hit.id, body_hit.id], title_first.map(&:id)
    assert_equal [both.id, body_hit.id, title_hit.id], body_first.map(&:id)
    assert_equal({ both.id => 13.5, title_hit.id => 12.5, body_hit.id => 1.0 }, scores(title_first))
    assert_equal 3, title_first.total_count
  end

  def test_zero_sql_weights_preserve_matches_in_single_and_multiple_field_searches
    title_hit, body_hit, both = boost_documents
    weighted = search("sunforge", fields: [{ "title^0" => :exact }, { "body^2" => :exact }])
    zero = search("sunforge", fields: [{ "title^0" => :exact }])

    assert_equal({ title_hit.id => 0.0, body_hit.id => 2.0, both.id => 2.0 }, scores(weighted))
    assert_equal({ title_hit.id => 0.0, both.id => 0.0 }, scores(zero))
    assert_equal 3, weighted.total_count
    assert_equal 2, zero.total_count
  end

  def test_whole_field_prefix_infix_and_suffix_weights_keep_their_match_modes
    title_hit, body_hit, both = boost_documents
    { text_start: "sun", text_middle: "unfor", text_end: "forge" }.each do |mode, term|
      page = search(term, fields: [{ "title^0.5" => mode }, { "body^2" => mode }])

      assert_equal [both.id, body_hit.id, title_hit.id], page.map(&:id)
      assert_equal({ both.id => 2.5, body_hit.id => 2.0, title_hit.id => 0.5 }, scores(page))
    end
    assert_empty search("unfor", fields: [{ "title^2" => :text_start }])
  end

  def test_mixed_native_and_exact_fields_add_their_own_scores
    title_hit, body_hit, both = boost_documents
    native = scores(search("sunforge", fields: ["body^1"]))
    mixed = scores(search("sunforge", fields: [{ "title^2.5" => :exact }, "body^1"]))

    assert_equal 2.5, mixed.fetch(title_hit.id)
    assert_score native.fetch(body_hit.id), mixed.fetch(body_hit.id)
    assert_score native.fetch(both.id) + 2.5, mixed.fetch(both.id)
  end

  def test_large_native_weight_scales_scores_beyond_the_tinql_limit
    baseline = scores(search("mithril lantern", fields: ["body^1"]))
    large = scores(search("mithril lantern", fields: ["body^20000"]))

    assert_equal 4, large.length
    assert_equal baseline.keys.sort, large.keys.sort
    baseline.each { |id, score| assert_score score * 20_000, large.fetch(id) }
  end

  def test_large_native_weights_reverse_ranking_and_count_each_matching_record_once
    title_hit, body_hit, both = boost_documents
    title_first = search("sunforge", fields: ["title^20000", "body^1"])
    body_first = search("sunforge", fields: ["title^1", "body^20000"])

    assert_equal [both.id, title_hit.id, body_hit.id], title_first.map(&:id)
    assert_equal [both.id, body_hit.id, title_hit.id], body_first.map(&:id)
    assert_equal 3, title_first.total_count
    assert_equal 3, body_first.total_count
  end

  def test_large_duplicate_weights_keep_last_explicit_resolution_and_sum_each_clause
    baseline = scores(search("mithril lantern", fields: ["body^1"]))
    duplicates = scores(search("mithril lantern", fields: ["body^20000", "body^40000", :body]))

    assert_equal baseline.keys.sort, duplicates.keys.sort
    baseline.each { |id, score| assert_score score * 120_000, duplicates.fetch(id) }
  end

  def test_large_weights_keep_refined_two_edit_candidates_and_eligibility
    baseline = scores(search("astorlbae", fields: ["body^1"], misspellings: { edit_distance: 2 }))
    large = scores(search("astorlbae", fields: ["body^30000"], misspellings: { edit_distance: 2 }))

    assert_equal [tinkick_test_documents(:typo_exact).id], large.keys
    baseline.each { |id, score| assert_score score * 30_000, large.fetch(id) }
  end

  def test_weighted_branches_preserve_filters_and_exclusions
    SearchDocument.create!(title: "An unrelated category", body: "mithril lantern", category: "fantasy")
    options = { where: { category: "control" }, exclude: "entrance" }
    baseline = search("mithril lantern", **options)
    large = search("mithril lantern", fields: ["body^20000"], **options)

    assert_equal 2, large.total_count
    assert_equal baseline.map(&:id).sort, large.map(&:id).sort
    assert large.all? { |record| record.category == "control" }
  end

  def test_large_weights_preserve_hidden_highlight_inputs_and_column_cursors_without_implicit_count
    options = { fields: ["body^20000"], highlight: true, load: false, select: [:title],
                order: :id, keyset: true, limit: 1 }
    page = search("mithril lantern", **options)
    statements = capture_queries do
      assert_equal 1, page.hits.length
      assert_equal ["title"], page.hits.first.fetch("_source").keys
      assert_includes page.highlights.first.fetch(:body), "<em>"
      assert page.has_next_page?
      refute_nil page.next_cursor
    end
    refute statements.any? { |statement| statement.fetch(:sql).match?(/COUNT\(/i) }
    following = search("mithril lantern", **options, after: page.next_cursor)

    refute_equal page.hits.first.fetch("_id"), following.hits.first.fetch("_id")
    assert_equal 4, following.total_count
  end

  def test_sql_weights_warn_once_for_cached_results_and_native_boosts_keep_the_fast_path
    output = StringIO.new
    previous_logger = SearchDocument.logger
    SearchDocument.logger = Logger.new(output)
    page = search("mithril lantern", fields: ["body^20000"])

    page.to_a
    page.to_a
    assert_equal 1, output.string.scan(/weighted SQL scoring/).length
    assert_includes output.string, "group"
    assert_includes output.string, "sort"
    output.truncate(0)
    output.rewind
    statements = capture_queries { search("mithril lantern", fields: ["body^10000"]).to_a }

    refute_includes output.string, "weighted SQL scoring"
    refute statements.any? { |statement| statement.fetch(:sql).include?("_tinkick_matches") }
  ensure
    SearchDocument.logger = previous_logger
  end

  private

  def boost_documents
    [
      SearchDocument.create!(title: "sunforge", body: "northern watch", category: "control"),
      SearchDocument.create!(title: "northern watch", body: "sunforge", category: "control"),
      SearchDocument.create!(title: "sunforge", body: "sunforge", category: "control"),
    ]
  end

  def search(term, **options)
    SearchDocument.tinkick_search(term, misspellings: false, **options)
  end

  def scores(relation)
    relation.with_score.to_h { |record, score| [record.id, score] }
  end

  def assert_score(expected, actual)
    assert_in_delta expected, actual, [expected.abs * 0.00001, 0.000001].max
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
