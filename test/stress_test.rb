# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class StressTest < ActiveSupport::TestCase
  self.fixture_paths = [File.expand_path("stress/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  def before_setup
    # Rails caches fixture sets by table, ignoring our alternate corpus path.
    ActiveRecord::FixtureSet.reset_cache
    super
  end

  def after_teardown
    super
  ensure
    ActiveRecord::FixtureSet.reset_cache
  end

  def test_fixed_ten_thousand_document_search_happy_paths
    assert_equal(10_000, SearchDocument.count)
    assert_equal({ "control" => 8, "fantasy" => 2_498, "food" => 2_498, "technical" => 2_498, "travel" => 2_498 }, SearchDocument.group(:category).count)

    ranked = search("mithril lantern", limit: 10).with_score.to_a
    ids = ranked.map { |record, _score| record.id }
    assert_equal([9_993, 9_994, 9_995, 9_996], ids.sort)
    assert_operator(ids.index(9_993), :<, ids.index(9_994))
    assert_operator(ids.index(9_995), :<, ids.index(9_996))
    assert_equal([9_993, 9_995], search("mithril lantern", limit: 2).map(&:id).sort)
    assert_empty(search("mithril lantern", where: { category: "food" }))

    assert_equal([9_997, 9_998, 9_999], search("Gondolin sentries").map(&:id).sort)
    assert_equal([9_997], search("Gondolin sentries", match: :phrase).map(&:id))
    assert_equal([10_000], SearchDocument.search("astrolbae", limit: 10).map(&:id))
    assert_empty(search("astrolbae"))
    assert_equal([10_000], search("astrola", match: :word_start).map(&:id))
    assert_equal([10_000], search("Navigation workshop", fields: [:title], match: :exact).map(&:id))

    counts = search("*", limit: 1, aggs: { category: { order: { _key: :asc } } })
    assert_equal([8, 2_498, 2_498, 2_498, 2_498], counts.aggs.fetch("category").fetch("buckets").map { |bucket| bucket.fetch("doc_count") })
    assert_equal(1, counts.size)
    assert_equal(10_000, counts.total_count)

    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      page = search("database", where: { category: "technical" }, limit: 20, countless: true)
      assert_equal(20, page.size)
      assert(page.has_next_page?)
      assert_equal(["technical"], page.map(&:category).uniq)
    end
    refute(statements.any? { |sql| /COUNT\s*\(/i.match?(sql) })

    traversed = []
    cursor = nil
    loop do
      page = search("*", where: { category: "technical" }, limit: 137, keyset: true, order: { id: :asc }, after: cursor)
      traversed.concat(page.map(&:id))
      cursor = page.next_cursor
      break unless cursor
    end
    assert_equal((4..9_992).step(4).to_a, traversed)

    document = SearchDocument.find(10_000)
    document.update!(body: "The workshop now repairs compasses and sextants.")
    assert_empty(search("astrolabe"))
    assert_equal([document.id], search("sextants").map(&:id))
  end

  private

  def search(term, **options)
    SearchDocument.tinkick_search(term, misspellings: false, **options)
  end
end
