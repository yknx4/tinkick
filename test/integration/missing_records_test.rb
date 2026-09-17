# frozen_string_literal: true

require_relative "../integration_helper"

class MissingRecordsTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  def test_missing_records_loads_only_the_scoped_page_and_keeps_totals
    identifier = tinkick_test_products(:red_apple).id.to_s
    search = Product.search("*", order: :id, limit: 1, scope_results: ->(records) { records.where(name: "Green Pear") })
    statements = capture_queries do
      assert_equal [{ id: identifier, model: Product }], search.missing_records
    end

    assert_empty search
    assert_equal 2, search.total_count
    assert_equal 2, search.next_page
    assert_equal 2, statements.count { |sql| sql.include?('FROM "tinkick_test_products"') }
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_empty capture_queries {
                   search.missing_records
                   search.to_a
                   search.with_score.to_a }
  end

  def test_missing_rows_keep_the_original_search_order_and_string_identifiers
    expected = Product.order(id: :desc).pluck(:id).map { |identifier| { id: identifier.to_s, model: Product } }
    query = Tinkick::Query.new(Product, "*", fields: [:name], order: { id: :desc })
    results = Tinkick::Results.new(query, scope_results: ->(records) { records.none })

    assert_equal expected, results.missing_records
    assert_empty results
    assert_same results.missing_records, results.missing_records
  end

  def test_rows_deleted_between_hit_selection_and_scoped_loading_are_reported
    identifier = tinkick_test_products(:red_apple).id
    callback = ->(records) {
      Product.where(id: identifier).delete_all
      records
    }
    search = Product.search("*", order: :id, scope_results: callback)
    assert_equal 2, search.total_count

    assert_equal [{ id: identifier.to_s, model: Product }], search.missing_records
    assert_equal ["Green Pear"], search.map(&:name)
    assert_equal [1.0], search.with_score.map { |_record, score| score }
    assert_equal 2, search.total_count
    assert_equal 1, Product.count
  end

  def test_empty_scoped_keyset_pages_keep_cursor_and_do_not_report_probe_rows
    identifier = tinkick_test_products(:red_apple).id.to_s
    callback = ->(records) { records.where(name: "Green Pear") }
    first = Product.search("*", keyset: true, limit: 1, scope_results: callback)
    statements = capture_queries do
      assert_equal [{ id: identifier, model: Product }], first.missing_records
      assert_empty first
      assert first.has_next_page?
      refute first.out_of_range?
      refute_nil first.next_cursor
    end

    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    second = Product.search("*", keyset: true, after: first.next_cursor, limit: 1, scope_results: callback)
    assert_empty second.missing_records
    assert_equal ["Green Pear"], second.map(&:name)
    refute second.has_next_page?
    assert_equal 2, second.total_count
  end

  def test_normal_and_raw_results_have_no_missing_records_and_reuse_the_page
    normal = Product.search("*", order: :id)
    assert_empty normal.missing_records
    assert_empty capture_queries { assert_equal ["Red Apple", "Green Pear"], normal.map(&:name) }

    raw = Product.search("*", load: false, select: [], scope_results: ->(_records) { raise "raw mode must ignore result scopes" })
    assert_empty raw.missing_records
    assert_empty capture_queries { assert_equal 2, raw.length }
    assert raw.all? { |record| record.to_h.keys == ["id"] }
    assert_empty Product.search("unfindablezzzz", misspellings: false).missing_records
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
