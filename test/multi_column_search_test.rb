# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class MultiColumnSearchTest < ActionDispatch::IntegrationTest
  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  setup do
    @title_hit = SearchDocument.create!(title: "Sunforge watch", body: "Sentries guard the northern tower", category: "control")
    @body_hit = SearchDocument.create!(title: "Northern watch", body: "Sentries guard the sunforge tower", category: "control")
    @both_hit = SearchDocument.create!(title: @title_hit.title, body: @body_hit.body, category: "control")
  end

  def test_either_column_matches_and_a_row_matching_both_is_returned_once
    page = search
    expected = [@title_hit.id, @body_hit.id, @both_hit.id].sort

    assert_equal 271, SearchDocument.count
    assert_equal expected, page.map(&:id).sort
    assert_equal expected.length, page.total_count
    assert_equal 1, search(limit: 1, countless: true).to_a.length
    assert search(limit: 1, countless: true).has_next_page?
  end

  def test_a_match_in_both_columns_ranks_above_each_single_column_match
    combined = scores
    assert_operator combined.fetch(@both_hit.id), :>, combined.fetch(@title_hit.id)
    assert_operator combined.fetch(@both_hit.id), :>, combined.fetch(@body_hit.id)
    assert_equal @both_hit.id, search.first.id
    assert_equal @both_hit.id, search(limit: 1, countless: true).first.id
  end

  def test_decimal_field_boosts_add_each_matching_columns_native_score
    title_scores = scores(fields: ["title^1"])
    body_scores = scores(fields: ["body^1"])
    combined = scores(fields: ["title^1.5", "body^1"])

    [@title_hit, @body_hit, @both_hit].each do |record|
      expected = title_scores.fetch(record.id, 0) * 1.5 + body_scores.fetch(record.id, 0)
      assert_operator expected, :>, 0
      assert_in_delta expected, combined.fetch(record.id), expected * 0.00001
    end
    assert_equal @both_hit.id, search(fields: ["title^1.5", "body^1"]).first.id
  end

  def test_filters_counts_and_highlighting_keep_the_same_multi_column_membership
    @body_hit.update!(category: "excluded")
    page = search(where: { category: "control" }, highlight: true)

    assert_equal [@title_hit.id, @both_hit.id].sort, page.map(&:id).sort
    assert_equal 2, page.total_count
    hits = page.hits.to_h { |hit| [hit.fetch("_id").to_i, hit] }
    both = hits.fetch(@both_hit.id).fetch("highlight")
    assert_match(/<em>Sunforge<\/em>/, both.fetch("title").join)
    assert_match(/<em>sunforge<\/em>/, both.fetch("body").join)
    assert_match(/<em>Sunforge<\/em>/, hits.fetch(@title_hit.id).fetch("highlight").fetch("title").join)
  end

  def test_column_cursors_traverse_multi_column_matches_without_duplicates
    ids = []
    cursor = nil
    loop do
      page = search(keyset: true, limit: 1, after: cursor)
      ids.concat(page.map(&:id))
      cursor = page.next_cursor
      break unless cursor
    end

    assert_equal [@title_hit.id, @body_hit.id, @both_hit.id].sort, ids
  end

  private

  def search(**options)
    SearchDocument.tinkick_search("sunforge", fields: [:title, :body], misspellings: false, **options)
  end

  def scores(**options)
    search(**options).with_score.to_h { |record, score| [record.id, score] }
  end
end
