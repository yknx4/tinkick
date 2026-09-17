# frozen_string_literal: true

require_relative "../test_helper"
require "tinkick/results"
require_relative "../integration_helper"

class ResultsTest < TinkickIntegrationTest
  class CallbackProduct < SearchProduct
    after_find { raise "load: false must not instantiate ActiveRecord models" }
  end

  test "construction is lazy and array operations enumerate only the requested page" do
    search = nil
    assert_empty(capture_queries { search = results(limit: 1, page: 2) })

    assert_equal ["Red Apple"], search.map(&:name)
    assert_instance_of Enumerator, search.each
    assert_equal search.to_a, search.each { |_record| }
    assert_equal search.to_a, search.to_ary
    assert_equal search.to_a, search[0, 1]
    assert_equal search.to_a, search.slice(0..0)
    assert_equal "Red Apple", search[0].name
    assert_equal "Red Apple", search[-1].name
    assert_nil search[1]
    assert search.any?
    assert search.any? { |record| record.name == "Red Apple" }
    refute search.empty?
    assert_equal 1, search.size
    assert_equal 1, search.length
    assert_equal 1, search.count
    assert_empty(capture_queries { search.to_a })
  end

  test "total count executes SQL without loading page models" do
    search = results(limit: 1)
    instantiations = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }

    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      statements = capture_queries { assert_equal 2, search.total_count }
      assert statements.any? { |sql| sql.match?(/COUNT\(/i) }
      assert_empty instantiations
      assert_equal 2, search.total_entries
      assert_equal 1, search.count
      assert_equal [1], instantiations
    end
  end

  test "pagination matches Searchkick navigation and aliases" do
    search = results(limit: 1, page: 2)

    assert_equal 2, search.current_page
    assert_equal 1, search.per_page
    assert_equal 1, search.limit_value
    assert_equal 2, search.total_pages
    assert_equal 2, search.num_pages
    assert_equal 1, search.offset
    assert_equal 1, search.offset_value
    assert_equal 1, search.previous_page
    assert_equal 1, search.prev_page
    assert_nil search.next_page
    refute search.first_page?
    assert search.last_page?
    refute search.out_of_range?

    first = results(limit: 1)
    assert_nil first.previous_page
    assert_equal 2, first.next_page
    assert first.first_page?
    refute first.last_page?
  end

  test "padding contributes to offset without reducing total pages" do
    search = results(limit: 1, padding: 1)

    assert_equal 1, search.padding
    assert_equal 1, search.offset_value
    assert_equal 2, search.total_pages
    assert_equal ["Red Apple"], search.map(&:name)
  end

  test "empty and out of range pages preserve upstream navigation behavior" do
    empty = results(term: "missing")

    assert empty.empty?
    assert_equal 0, empty.total_count
    assert_equal 0, empty.total_pages
    assert empty.first_page?
    assert empty.last_page?
    assert empty.out_of_range?

    beyond = results(limit: 1, page: 3)
    assert beyond.empty?
    assert_equal 2, beyond.total_count
    assert_equal 2, beyond.previous_page
    assert_nil beyond.next_page
    assert beyond.out_of_range?
  end

  test "total entries override avoids the count query including zero" do
    [0, 15].each do |total|
      search = results(limit: 2, total_entries: total)

      statements = capture_queries do
        assert_equal total, search.total_count
        assert_equal total, search.total_entries
        assert_equal((total / 2.0).ceil, search.total_pages)
      end

      assert_empty statements
      assert_equal 2, search.count
    end
  end

  test "with score enumerates paired records and numeric relevance" do
    search = results(term: "apple", order: nil)

    assert_instance_of Enumerator, search.with_score
    pairs = search.with_score.to_a
    assert_equal ["Red Apple"], pairs.map { |record, _score| record.name }
    assert pairs.all? { |_record, score| score.is_a?(Float) && score >= 0 }

    yielded = []
    search.with_score { |record, score| yielded << [record, score] }
    assert_equal pairs, yielded
    assert_equal search.to_a, pairs.map(&:first)
  end

  test "load false wraps raw rows without ActiveRecord instantiation or callbacks" do
    search = results(model: CallbackProduct, load: false, limit: 1)
    expected_id = tinkick_test_products(:green_pear).id
    instantiations = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiations << payload[:record_count] }

    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      result = search.first
      assert_instance_of Tinkick::HashWrapper, result
      assert_equal "Green Pear", result.name
      assert_equal "Green Pear", result[:name]
      assert_equal expected_id, result.id
      refute result.to_h.key?("_tinkick_score")
      assert_equal [[result, 1.0]], search.with_score.to_a
      assert_equal 2, search.total_count
    end

    assert_empty instantiations
    assert_empty(capture_queries { search.to_a })
  end

  test "load false preserves bound full text and filter conditions" do
    query = Tinkick::Query.new(
      CallbackProduct,
      "apple",
      fields: [:name],
      where: { description: "Fresh orchard fruit" },
      limit: 1,
    )
    search = Tinkick::Results.new(query, load: false)

    assert_equal ["Red Apple"], search.map(&:name)
    assert_operator search.with_score.first.last, :>=, 0
    assert_equal 1, search.total_count
  end

  private

  def results(model: SearchProduct, term: "*", limit: 10, page: 1, padding: 0, total_entries: nil, load: true, order: :name)
    query = Tinkick::Query.new(model, term, fields: [:name], order: order, limit: limit, offset: (page - 1) * limit + padding)
    Tinkick::Results.new(query, page: page, padding: padding, total_entries: total_entries, load: load)
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
