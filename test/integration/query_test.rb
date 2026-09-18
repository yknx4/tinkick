# frozen_string_literal: true

require_relative "../integration_helper"

class QueryTest < TinkickIntegrationTest
  class ScopedProduct < SearchProduct
    default_scope { where(name: "Red Apple") }
  end

  def test_construction_is_lazy
    statements = capture_queries { query("apple") }

    assert_empty(statements)
  end

  def test_returns_active_record_models_matching_selected_fields
    records = query("orchard", fields: [:description]).records

    assert_equal(["Red Apple"], records.map(&:name))
    assert_instance_of(SearchProduct, records.first)
    assert_empty(query("orchard", fields: [:name]).records)
  end

  def test_terms_must_match_within_one_field
    assert_empty(query("red orchard", fields: [:name, :description]).records)
    assert_equal(["Red Apple"], query("red orchard", fields: [:name, :description], operator: "or").records.map(&:name))
    assert_equal(["Green Pear", "Red Apple"], query("apple ripe", fields: [:name, :description], operator: "or", order: :name).records.map(&:name))
  end

  def test_phrase_matching
    assert_equal(["Red Apple"], query("red apple", match: :phrase).records.map(&:name))
    assert_empty(query("apple red", match: :phrase).records)
  end

  def test_filters_apply_to_records_and_counts
    search = query("fruit", fields: [:description], where: { name: "Green Pear" })

    assert_equal(["Green Pear"], search.records.map(&:name))
    assert_equal(1, search.total_count)
  end

  def test_uses_native_scoring_for_common_terms
    tinkick_test_products(:red_apple).update!(name: "Apple apple")
    tinkick_test_products(:green_pear).update!(name: "Apple pear")
    records = nil
    statements = capture_queries { records = query("apple").records }

    assert_equal(["Apple apple", "Apple pear"], records.map(&:name).sort)
    scores = records.map { |record| record["_tinkick_score"] }
    assert_equal(scores.sort.reverse, scores)
    assert(scores.all? { |score| score >= 0 })
    assert(statements.any? { |entry| entry[:sql].include?("tin.score(") })
    refute(statements.any? { |entry| entry[:sql].include?("tin.full_score(") })
    refute(records.first.attributes.key?("ctid"))
  end

  def test_explicit_order_can_stabilize_tied_pages
    tinkick_test_products(:red_apple).update!(name: "Apple")
    tinkick_test_products(:green_pear).update!(name: "Apple")
    expected = SearchProduct.order(:id).ids

    assert_equal(expected, query("apple", order: :id).records.map(&:id))
    assert_equal([expected.first], query("apple", order: :id, limit: 1).records.map(&:id))
    assert_equal([expected.last], query("apple", order: :id, limit: 1, offset: 1).records.map(&:id))
  end

  def test_match_all_uses_sql_without_tin_scoring
    search = query("*", order: { name: :desc })
    statements = capture_queries do
      assert_equal(["Red Apple", "Green Pear"], search.records.map(&:name))
      assert_equal(2, search.total_count)
    end

    refute(statements.any? { |statement| statement[:sql].include?("tin.full_score") })
    refute(statements.any? { |statement| statement[:sql].include?("tin.score") })
    refute(statements.any? { |statement| statement[:sql].include?("tin.tokenize") })
    assert_equal([1.0, 1.0], search.records.map { |record| record["_tinkick_score"] })
  end

  def test_empty_queries_match_nothing
    ["", " ", "!!!"].each do |term|
      search = query(term)

      assert_empty(search.records)
      assert_equal(0, search.total_count)
    end
  end

  def test_count_does_not_load_records_and_records_load_only_the_page
    search = query("fruit", fields: [:description], limit: 1, offset: 1)
    instantiations = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }

    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      assert_equal(2, search.total_count)
      assert_empty(instantiations)
      assert_equal(1, search.records.length)
      assert_equal([1], instantiations)
    end
    assert_empty(capture_queries { search.records })
  end

  def test_order_accepts_fields_and_multiple_directions
    assert_equal(["Green Pear", "Red Apple"], query("*", order: "name").records.map(&:name))
    assert_equal(["Red Apple", "Green Pear"], query("*", order: [{ name: :desc }, :id]).records.map(&:name))
  end

  def test_default_scope_is_preserved
    search = Tinkick::Query.new(ScopedProduct, "*", fields: [:name])

    assert_equal(["Red Apple"], search.records.map(&:name))
    assert_equal(1, search.total_count)
  end

  def test_search_observes_writes_and_rollback
    SearchProduct.transaction(requires_new: true) do
      product = SearchProduct.create!(name: "Orange", description: "Citrus")
      assert_equal([product.id], query("orange").records.map(&:id))

      product.update!(name: "Lemon")
      assert_empty(query("orange").records)
      assert_equal([product.id], query("lemon").records.map(&:id))

      product.destroy!
      assert_equal(0, query("lemon").total_count)

      SearchProduct.create!(name: "Lime")
      assert_equal(1, query("lime").total_count)
      raise ActiveRecord::Rollback
    end

    assert_equal(0, query("lime").total_count)
  end

  def test_actual_ranked_query_uses_the_tin_index
    statements = capture_queries { query("apple", limit: 1).records }
    statement = statements.find { |entry| entry[:sql].include?("_tinkick_score") }
    plan_json = SearchProduct.connection.select_value("EXPLAIN (FORMAT JSON) #{statement[:sql]}", "Tinkick Explain", statement[:binds])
    nodes = plan_nodes(JSON.parse(plan_json).first.fetch("Plan"))
    scans = nodes.select { |node| node["Custom Plan Provider"] == "Text Search Scan" }

    assert_equal("Limit", nodes.first["Node Type"])
    assert_includes(statement[:sql], "tin.score")
    require_production_tin_plan!
    assert_equal(["index_tinkick_test_products_on_name"], scans.map { |node| node["Index"] })
    assert_equal("1", scans.first["Top K"])
    assert_equal("dense-term elision", scans.first["Scoring"])
    refute(nodes.any? { |node| node["Node Type"] == "Sort" })
  end

  def test_invalid_fields_and_sort_identifiers_fail
    assert_raises(Tinkick::MissingFieldError) { query("apple", fields: ["missing"]).records }
    assert_raises(Tinkick::MissingFieldError) { query("*", order: "name; SELECT 1").records }
    assert_raises(Tinkick::InvalidQueryError) { query("apple", fields: [:id]).records }
    assert_raises(ArgumentError) { query("*", order: { name: "desc; SELECT 1" }).records }
    assert_raises(ArgumentError) { query("apple", fields: []).records }
  end

  def test_offset_pagination_warns_when_the_ranked_page_is_fetched
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    search = query("apple", offset: 1)

    search.total_count
    refute_includes(output.string, "Tinkick:")
    search.records
    assert_includes(output.string, "offset pagination")
    assert_includes(output.string, "top-k")
    assert_includes(output.string, "keyset pagination")
    assert_includes(output.string, "does not remove offset costs")

    output.truncate(0)
    output.rewind
    search.records
    query("apple").records
    refute_includes(output.string, "Tinkick:")
  ensure
    SearchProduct.logger = original_logger
  end

  def test_multiple_ranked_fields_warn_when_records_are_fetched
    original_logger = SearchProduct.logger
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    search = query("fruit", fields: [:name, :description])

    search.total_count
    refute_includes(output.string, "Tinkick:")
    search.records
    assert_includes(output.string, "multiple fields")
    assert_includes(output.string, "generated")
    assert_includes(output.string, "TIN index")
    assert_includes(output.string, "EXPLAIN ANALYZE")

    output.truncate(0)
    output.rewind
    search.records
    query("apple").records
    query("*", fields: [:name, :description]).records
    refute_includes(output.string, "Tinkick:")
  ensure
    SearchProduct.logger = original_logger
  end

  def test_multiple_fields_preserve_matches_with_native_scoring
    search = query("apple ripe", fields: [:name, :description], operator: "or", order: :name)
    statements = capture_queries do
      assert_equal(["Green Pear", "Red Apple"], search.records.map(&:name))
      assert_equal(search.total_count, search.records.length)
    end
    assert(statements.any? { |entry| entry[:sql].include?("tin.score(") })
    refute(statements.any? { |entry| entry[:sql].include?("tin.full_score(") })
  end

  private

  def query(term, **options)
    Tinkick::Query.new(SearchProduct, term, fields: [:name], **options)
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  def plan_nodes(node)
    [node] + node.fetch("Plans", []).flat_map { |child| plan_nodes(child) }
  end
end
