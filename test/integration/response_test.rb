# frozen_string_literal: true

require_relative "../integration_helper"

class ResponseTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  def test_response_contains_portable_hits_exact_totals_and_requested_aggregations
    search = Product.search("*", select: :name, order: :name, limit: 1, aggs: [:name],
      scope_results: ->(_records) { raise "metadata must not invoke the result scope" })
    response = search.response

    assert_equal %w[aggregations hits took], response.keys.sort
    assert_equal({ "value" => 2, "relation" => "eq" }, response.fetch("hits").fetch("total"))
    assert_same search.hits, response.fetch("hits").fetch("hits")
    assert_equal ["Green Pear"], response.fetch("hits").fetch("hits").map { |hit| hit.fetch("_source").fetch("name") }
    assert_equal search.aggregations, response.fetch("aggregations")
    assert_equal search.took, response.fetch("took")
    assert_empty capture_queries { assert_same response, search.response }
  end

  def test_countless_responses_omit_unknown_totals_without_count_queries
    [{ countless: true }, { keyset: true, order: :name }].each do |options|
      search = Product.search("*", limit: 1, **options)
      statements = capture_queries do
        response = search.response
        assert_equal %w[hits took], response.keys.sort
        assert_equal ["hits"], response.fetch("hits").keys
        assert_equal 1, response.fetch("hits").fetch("hits").length
        assert search.has_next_page?
        refute_nil search.next_cursor if options[:keyset]
      end
      refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
      assert_equal 1, statements.count { |sql| sql.include?(" AS _tinkick_score") }
    end
  end

  def test_supplied_totals_are_preserved_without_counting_even_in_countless_mode
    search = Product.search("*", countless: true, limit: 1, total_entries: 99)
    statements = capture_queries do
      assert_equal({ "value" => 99, "relation" => "eq" }, search.response.fetch("hits").fetch("total"))
      assert_equal 99, search.total_count
    end
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
  end

  def test_raw_response_sources_keep_database_types_and_serialize_to_json
    tinkick_test_products(:red_apple).update!(metadata: { hero: "Arwen", active: false }, tags: ["Rivendell", "Moria"])
    search = Product.search("apple", misspellings: false, load: false, select: [:metadata, :tags])
    response = JSON.parse(search.response.to_json)
    source = response.fetch("hits").fetch("hits").first.fetch("_source")

    assert_equal({ "hero" => "Arwen", "active" => false }, source.fetch("metadata"))
    assert_equal ["Rivendell", "Moria"], source.fetch("tags")
    assert_equal({ "value" => 1, "relation" => "eq" }, response.fetch("hits").fetch("total"))
    assert_empty capture_queries {
      assert_equal [{ "hero" => "Arwen", "active" => false }], search.with_hit.map { |row, _hit| row.metadata }
    }
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
