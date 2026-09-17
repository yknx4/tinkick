# frozen_string_literal: true

require_relative "../../lib/tinkick/model"
require_relative "../integration_helper"

class CountlessTest < TinkickIntegrationTest
  test "navigation probes one extra row without counting" do
    search = relation(countless: true, limit: 1, order: :name)
    statements = capture_queries do
      assert_equal ["Green Pear"], search.map(&:name)
      assert search.has_next_page?
      assert_equal 2, search.next_page
      refute search.last_page?
      refute search.out_of_range?
    end

    refute statements.any? { |entry| entry[:sql].include?("COUNT(") }
    statement = page_statement(statements)
    assert_equal 2, statement[:binds].last.value_for_database
    assert_empty(capture_queries { search.has_next_page? })

    counts = capture_queries do
      assert_equal 2, search.total_count
      assert_equal 2, search.total_pages
    end
    assert_equal 1, counts.count { |entry| entry[:sql].include?("COUNT(") }
  end

  test "empty and final pages have no next page without a count" do
    final = relation(countless: true, limit: 1, page: 2, order: :name)
    beyond = relation(countless: true, limit: 1, page: 3, order: :name)
    statements = capture_queries do
      assert_equal ["Red Apple"], final.map(&:name)
      refute final.has_next_page?
      assert_nil final.next_page
      assert final.last_page?
      refute final.out_of_range?
      assert beyond.empty?
      assert beyond.out_of_range?
      assert beyond.last_page?
    end
    refute statements.any? { |entry| entry[:sql].include?("COUNT(") }
  end

  test "relevance preserves native TIN top k with an extra row" do
    statements = capture_queries { relation("fruit", fields: [:description], countless: true, limit: 1).to_a }
    statement = page_statement(statements)
    json = SearchProduct.connection.select_value("EXPLAIN (FORMAT JSON) #{statement[:sql]}", "Tinkick Explain", statement[:binds])
    nodes = plan_nodes(JSON.parse(json).first.fetch("Plan"))
    scan = nodes.find { |node| node["Custom Plan Provider"] == "Text Search Scan" }

    refute_includes statement[:sql], "OFFSET"
    require_production_tin_plan!
    assert_equal "2", scan.fetch("Top K")
    refute nodes.any? { |node| node["Node Type"] == "Sort" }
  end

  test "requires a positive page limit but first zero does not query" do
    assert_raises(Tinkick::InvalidQueryError) { relation(countless: true, limit: 0) }
    search = relation(countless: true, limit: 1)
    assert_empty(capture_queries { assert_equal [], search.first(0) })
    refute search.loaded?
  end

  test "fluent mode clones and rejects loaded mutations" do
    base = relation(limit: 1)
    search = base.countless

    refute_same base, search
    assert_equal 2, search.next_page
    refute base.loaded?
    assert_raises(Tinkick::Error) { search.countless! }
    assert_equal 2, search.countless(false).total_count
  end

  test "raw results trim the probe row and expose count-free navigation" do
    search = relation(countless: true, load: false, limit: 1, order: :name)
    statements = capture_queries do
      assert_equal 1, search.size
      assert_instance_of Tinkick::HashWrapper, search.to_a.first
      assert_equal "Green Pear", search.to_a.first.name
      assert search.has_next_page?
      assert_equal 2, search.next_page
    end
    refute statements.any? { |entry| entry[:sql].include?("COUNT(") }
  end

  test "registered models forward the countless option" do
    model = Class.new(SearchProduct) do
      extend Tinkick::Model
      tinkick(searchable: [:name])
    end
    search = model.tinkick_search("*", countless: true, limit: 1, order: :name)

    statements = capture_queries do
      assert_equal ["Green Pear"], search.map(&:name)
      assert search.has_next_page?
      assert_equal 2, search.next_page
    end
    refute statements.any? { |entry| entry[:sql].include?("COUNT(") }
  end

  private

  def relation(term = "*", **options)
    Tinkick::Relation.new(SearchProduct, term, fields: [:name], misspellings: false, **options)
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  def page_statement(statements)
    statements.find { |entry| entry[:sql].include?("AS _tinkick_score") }
  end

  def plan_nodes(node)
    [node] + node.fetch("Plans", []).flat_map { |child| plan_nodes(child) }
  end
end
