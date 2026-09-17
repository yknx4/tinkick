# frozen_string_literal: true

require_relative "../integration_helper"
require "base64"

class PaginationTest < TinkickIntegrationTest
  class ScopedProduct < SearchProduct
    default_scope { where(name: "Red Apple") }
  end

  test "keyset defaults to primary key and gives an opaque continuation cursor" do
    expected = SearchProduct.order(:id).ids
    first = relation(keyset: true, limit: 1)
    statements = capture_queries do
      assert_equal [expected.first], first.map(&:id)
      assert first.has_next_page?
      assert first.first_page?
      refute first.last_page?
    end
    cursor = first.next_cursor
    assert_kind_of String, cursor
    assert_match(/\A[A-Za-z0-9_-]+\z/, cursor)

    second = relation(keyset: true, after: cursor, limit: 1)
    statements += capture_queries do
      assert_equal [expected.last], second.map(&:id)
      refute second.first_page?
      assert second.last_page?
      refute second.has_next_page?
      assert_nil second.next_cursor
      refute second.out_of_range?
    end
    refute statements.any? { |entry| entry[:sql].include?("COUNT(") || entry[:sql].include?("OFFSET") }
    assert_equal 2, second.total_count
    assert_equal 2, second.total_pages
    error = assert_raises(Tinkick::InvalidQueryError) { first.next_page }
    assert_includes error.message, "next_cursor"
  end

  test "keyset appends primary key to make duplicate column order stable" do
    SearchProduct.update_all(name: "Apple")
    extra = SearchProduct.create!(name: "Banana")
    first = relation(keyset: true, limit: 1, order: { name: :asc })
    seen = []
    search = first
    loop do
      seen.concat(search.map(&:id))
      break unless search.has_next_page?

      search = relation(keyset: true, after: search.next_cursor, limit: 1, order: { name: :asc })
    end

    assert_equal SearchProduct.order(:name, :id).ids, seen
    assert_equal extra.id, seen.last
    assert_equal seen.uniq, seen
  end

  test "keyset supports descending and mixed column directions" do
    SearchProduct.create!(name: "Red Apple")
    expected = SearchProduct.order(name: :desc, id: :asc).ids
    first = relation(keyset: true, limit: 2, order: { name: :desc })
    second = relation(keyset: true, after: first.next_cursor, limit: 2, order: { name: :desc })
    assert_equal expected, first.map(&:id) + second.map(&:id)

    first = relation(keyset: true, limit: 1, order: { id: :desc })
    second = relation(keyset: true, after: first.next_cursor, limit: 2, order: { id: :desc })
    assert_equal SearchProduct.order(id: :desc).ids, first.map(&:id) + second.map(&:id)
  end

  test "keyset continuation survives inserts and deletes before the cursor" do
    first = relation(keyset: true, limit: 1, order: :name)
    assert_equal ["Green Pear"], first.map(&:name)
    cursor = first.next_cursor
    tinkick_test_products(:green_pear).destroy!
    SearchProduct.create!(name: "Apricot")
    second = relation(keyset: true, after: cursor, limit: 1, order: :name)
    assert_equal ["Red Apple"], second.map(&:name)
  end

  test "cursor values remain bound and model scopes still apply" do
    tinkick_test_products(:green_pear).update!(name: "' OR TRUE --")
    first = relation(keyset: true, limit: 1, order: :name)
    cursor = first.next_cursor
    second = relation(keyset: true, after: cursor, limit: 1, order: :name, where: { name: "Red Apple" })
    statements = capture_queries { assert_equal ["Red Apple"], second.map(&:name) }
    statement = page_statement(statements)
    refute_includes statement[:sql], "' OR TRUE --"
    assert statement[:binds].any? { |bind| bind == "' OR TRUE --" }

    scoped = Tinkick::Relation.new(ScopedProduct, "*", fields: [:name], misspellings: false,
      keyset: true, after: cursor, limit: 1, order: :name)
    assert_equal ["Red Apple"], scoped.map(&:name)
  end

  test "keyset rejects malformed mismatched and wrongly typed cursors" do
    first = relation(keyset: true, limit: 1)
    cursor = first.next_cursor
    ["not base64!", Base64.urlsafe_encode64("[]", padding: false), "", "a", false, 123, [], {}].each do |invalid|
      assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, after: invalid).to_a }
    end
    assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, after: cursor, order: :name).to_a }
    payload = JSON.parse(Base64.urlsafe_decode64(cursor))
    [payload.merge("version" => 2), payload.merge("table" => "other"), payload.merge("values" => ["1; SELECT 1"]), payload.merge("values" => [])].each do |invalid|
      encoded = Base64.urlsafe_encode64(JSON.generate(invalid), padding: false)
      assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, after: encoded).to_a }
    end
  end

  test "keyset rejects nullable columns and invalid or repeated ordering" do
    error = assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, order: :description).to_a }
    assert_includes error.message, "NOT NULL"
    assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, order: ["name", { name: :desc }]).to_a }
    assert_raises(Tinkick::MissingFieldError) { relation(keyset: true, order: "name; DROP TABLE x").to_a }
    assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, order: :_score).to_a }
  end

  test "opted in pagination rejects conflicting options and zero limits" do
    [{ offset: 0 }, { offset: 1 }, { page: 2 }, { padding: 1 }, { limit: 0 }].each do |options|
      assert_raises(Tinkick::InvalidQueryError) { relation(keyset: true, **options).to_a }
    end
    assert_raises(Tinkick::InvalidQueryError) { relation(after: "cursor").to_a }
    assert_raises(Tinkick::InvalidQueryError) { relation(countless: true, limit: 0).to_a }
    query = Tinkick::Query.new(SearchProduct, "*", fields: [:name], keyset: true, limit: 1)
    assert_raises(Tinkick::InvalidQueryError) { Tinkick::Results.new(query, page: 2) }
    assert_raises(Tinkick::InvalidQueryError) { Tinkick::Results.new(query, padding: 1) }
  end

  test "fluent pagination clones and rejects loaded mutations" do
    base = relation(limit: 1)
    first = base.keyset
    assert_nil base.next_cursor
    assert first.has_next_page?
    assert first.keyset(after: first.next_cursor).last_page?
    assert_equal 2, base.countless.next_page
    assert_raises(Tinkick::Error) { first.keyset! }
    assert_raises(Tinkick::Error) { first.countless! }
  end

  test "load false trims the probe and can generate the same cursor" do
    first = relation(keyset: true, limit: 1, load: false)
    assert_instance_of Tinkick::HashWrapper, first.first
    assert first.has_next_page?
    assert_equal 1, first.size
    second = relation(keyset: true, after: first.next_cursor, limit: 1, load: false)
    assert_equal SearchProduct.order(:id).ids, first.map(&:id) + second.map(&:id)
    assert_nil second.next_cursor
  end

  test "primary key cursor produces a bounded predicate without OFFSET" do
    first = relation(keyset: true, limit: 1)
    cursor = first.next_cursor
    statements = capture_queries { relation(keyset: true, after: cursor, limit: 1).to_a }
    statement = page_statement(statements)
    assert_match(/"id" > \$/, statement[:sql])
    refute_includes statement[:sql], "OFFSET"
    assert explain(statement).any? { |node| node.to_s.include?("id >") }
  end

  test "lexical column order warns about the measured sort instead of claiming relevance top k" do
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    search = relation("fruit", fields: [:description], keyset: true, order: :name, limit: 1)
    search.total_count
    refute_includes output.string, "Tinkick:"
    statements = capture_queries { search.to_a }
    nodes = explain(page_statement(statements))
    assert nodes.any? { |node| node["Node Type"] == "Sort" }
    refute nodes.any? { |node| node.key?("Top K") }
    assert_includes output.string, "column order"
    assert_includes output.string, "sort matching rows"
    output.truncate(0)
    output.rewind
    search.to_a
    refute_includes output.string, "Tinkick:"
  ensure
    SearchProduct.logger = original_logger
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

  def explain(statement)
    json = SearchProduct.connection.select_value("EXPLAIN (FORMAT JSON) #{statement[:sql]}", "Tinkick Explain", statement[:binds])
    plan_nodes(JSON.parse(json).first.fetch("Plan"))
  end

  def plan_nodes(node)
    [node] + node.fetch("Plans", []).flat_map { |child| plan_nodes(child) }
  end
end
