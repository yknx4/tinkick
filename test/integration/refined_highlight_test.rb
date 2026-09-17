# frozen_string_literal: true

require_relative "../integration_helper"

class RefinedHighlightTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  def test_two_edit_highlights_verify_each_token_in_the_returned_page
    tinkick_test_products(:red_apple).update!(name: "abcdefghij zzdcfeghxj abdcfeghij")
    search = Product.search("abdcfeghij", misspellings: { edit_distance: 2 }, highlight: true, countless: true)
    statements = capture_queries do
      assert_equal [{ name: "<em>abcdefghij</em> zzdcfeghxj <em>abdcfeghij</em>" }], search.highlights
      assert_equal search.highlights.first, search.to_a.first.search_highlights
    end
    assert_equal 1, statements.count { |sql| sql.include?("WITH tinkick_query_tokens AS MATERIALIZED") }
    assert_equal 1, statements.count { |sql| sql.include?("tin.highlight(") }
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_empty capture_queries { search.highlights }
  end

  def test_two_edit_partial_highlights_preserve_whole_token_spans
    tinkick_test_products(:red_apple).update!(name: "pineappletree by the orchard")
    search = Product.search("papel", match: :word_middle, misspellings: { edit_distance: 2 }, highlight: true)
    assert_equal [{ name: "<em>pineappletree</em> by the orchard" }], search.highlights
  end

  def test_exact_first_decision_controls_the_highlight_query
    tinkick_test_products(:red_apple).update!(name: "abdcfeghij abcdefghij")
    search = Product.search("abdcfeghij", misspellings: { edit_distance: 2, below: 1 }, highlight: true)
    statements = capture_queries do
      assert_equal [{ name: "<em>abdcfeghij</em> abcdefghij" }], search.highlights
      refute search.misspellings?
    end
    refute statements.any? { |sql| sql.include?("WITH tinkick_query_tokens AS MATERIALIZED") }
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
