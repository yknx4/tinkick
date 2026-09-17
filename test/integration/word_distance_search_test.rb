# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class WordDistanceSearchTest < TinkickIntegrationTest
  def test_public_two_edit_search_matches_records_counts_and_projection
    results = search("papel")

    assert_equal(["Red Apple"], results.map(&:name))
    assert_equal(1, results.total_count)
    assert_equal(["Red Apple"], search("papel").pluck(:name))
    assert_empty(search("papel", misspellings: true))
    assert_empty(search("papel", misspellings: false))
    assert_equal(["Red Apple"], search("papel", misspellings: { distance: 2 }).map(&:name))
    assert_raises(ArgumentError) { search("apple", misspellings: { edit_distance: 2.0 }).to_a }
  end

  def test_multiple_fields_and_sql_modes_preserve_matches_and_filters
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    pear.update!(description: "Apple orchard")
    results = search("papel", fields: [:name, :description], order: :id)

    assert_equal([apple.id, pear.id].sort, results.map(&:id))
    assert_equal(2, results.total_count)
    assert_equal([apple.id], search("papel", fields: [:name, :description], where: { id: apple.id }).map(&:id))

    pear.update!(name: "papel")
    apple.update!(description: "Apple")
    mixed = search("papel", fields: [{ name: :exact }, :description], order: :id)
    assert_equal([apple.id, pear.id].sort, mixed.map(&:id))
    assert_equal(2, mixed.total_count)
  end

  def test_json_scalar_guards_stay_attached_to_the_refinement
    tinkick_test_products(:red_apple).update!(metadata: { title: "Apple" })
    tinkick_test_products(:green_pear).update!(metadata: { title: { text: "Apple" } })
    results = search("papel", fields: ["metadata.title"])

    assert_equal(["Red Apple"], results.map(&:name))
    assert_equal(1, results.total_count)
  end

  def test_long_tokens_use_bounded_distance_refinement_without_regex_expansion
    word = "ab#{"c" * 180}de"
    query = "ba#{"c" * 180}ed"
    tinkick_test_products(:red_apple).update!(name: word)
    statements = capture_queries do
      assert_equal([word], search(query).map(&:name))
    end
    statement = statements.find { |entry| entry[:sql].include?(" AS _tinkick_score") }

    refute_nil(statement)
    assert_operator(statement.fetch(:sql).length, :<, 5_000)
    refute_includes(statement.fetch(:sql), query)
    refute_includes(statement.fetch(:sql), "MATCHES")
  end

  def test_phrase_and_zero_distance_keep_their_existing_behavior
    assert_equal(["Red Apple"], search("Red Apple", match: :phrase, misspellings: false).map(&:name))
    assert_equal(["Red Apple"], search("apple", misspellings: { edit_distance: 0 }).map(&:name))
    assert_empty(search("papel", misspellings: { edit_distance: 0 }))
    assert_empty(search(""))
  end

  def test_refined_query_keeps_indexed_candidates_and_every_eligible_id
    tinkick_test_products(:red_apple).update!(name: "Apple")
    tinkick_test_products(:green_pear).update!(name: "Apple apple")
    statements = capture_queries do
      results = search("papel", limit: 10)
      assert_equal(SearchProduct.order(:id).ids, results.map(&:id).sort)
      assert_equal(2, results.total_count)
    end
    statement = statements.find { |entry| entry[:sql].include?(" AS _tinkick_score") }
    plan = SearchProduct.connection.select_value(
      "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
      "Tinkick Two Edit Explain", statement.fetch(:binds),
    )

    assert_includes(plan, "Text Search Scan")
    assert_includes(plan, "index_tinkick_test_products_on_name")
    assert_includes(plan, '"Function Name": "tokenize"')
    assert_includes(plan, '"Node Type": "Sort"')
    refute_includes(plan, '"Top K"')
  end

  private

  def search(term, **options)
    @model ||= Class.new(SearchProduct) { tinkick searchable: [:name] }
    @model.search(term, misspellings: { edit_distance: 2 }, **options)
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
