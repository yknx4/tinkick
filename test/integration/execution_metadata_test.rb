# frozen_string_literal: true

require_relative "../integration_helper"

class ExecutionMetadataTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  class DelayedProduct < Product
    default_scope { where("EXISTS (SELECT 1 FROM pg_sleep(0.04))") }
  end

  class InvalidProduct < Product
    default_scope { where("tinkick_metadata_missing_column = 1") }
  end

  def test_took_measures_a_real_page_fetch_and_reuses_it_without_counting
    search = DelayedProduct.search("*", order: :id, countless: true, limit: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    statements = capture_queries { assert_kind_of Integer, search.took }
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
    duration = search.took

    assert_operator duration, :>=, 40
    assert_operator duration, :<=, elapsed.ceil
    assert_equal 1, page_queries(statements).length
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_empty capture_queries {
      assert_equal duration, search.took
      assert_nil search.error
      assert_equal ["Red Apple"], search.map(&:name)
      assert search.has_next_page?
    }
  end

  def test_raw_projected_metadata_and_results_share_one_bounded_query_in_either_order
    [true, false].each do |metadata_first|
      search = Product.search("*", load: false, select: :name, order: :id, keyset: true, limit: 1)
      statements = capture_queries do
        metadata_first ? search.took : search.to_a
        duration = search.took
        assert_kind_of Integer, duration
        assert_operator duration, :>=, 0
        assert_nil search.error
        assert_equal ["Red Apple"], search.map(&:name)
        assert_equal %w[id name], search.first.to_h.keys.sort
        assert search.has_next_page?
        refute_nil search.next_cursor
        assert_equal duration, search.took
      end
      assert_equal 1, page_queries(statements).length
      refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    end
  end

  def test_metadata_does_not_invoke_result_scopes
    search = Product.search("*", scope_results: ->(_records) { raise "result scope executed" })
    statements = capture_queries do
      assert_nil search.error
      assert_kind_of Integer, search.took
    end
    assert_equal 1, page_queries(statements).length
    assert_equal "result scope executed", assert_raises(RuntimeError) { search.to_a }.message
  end

  def test_later_counts_and_aggregations_do_not_replace_the_page_duration
    search = Product.search("*", limit: 1, aggs: [:name])
    duration = search.took

    assert_equal 2, search.total_count
    assert_equal 2, search.aggs.fetch("name").fetch("buckets").length
    assert_empty capture_queries { assert_equal duration, search.took }
  end

  def test_database_failures_still_raise_and_do_not_record_successful_time
    query = Tinkick::Query.new(InvalidProduct, "*", fields: [:name])
    results = Tinkick::Results.new(query)
    Product.transaction(requires_new: true) do
      assert_raises(ActiveRecord::StatementInvalid) { results.error }
      raise ActiveRecord::Rollback
    end
    assert_nil query.took
  end

  def test_empty_pages_have_success_metadata
    search = Product.search("unfindablezzzz", misspellings: false)

    assert_nil search.error
    assert_kind_of Integer, search.took
    assert_empty capture_queries { assert_empty search }
  end

  private

  def page_queries(statements)
    statements.select { |sql| sql.include?(" AS _tinkick_score") }
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
