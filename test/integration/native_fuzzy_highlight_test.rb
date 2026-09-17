# frozen_string_literal: true

require_relative "../integration_helper"

class NativeFuzzyHighlightTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  def test_native_fuzzy_highlights_the_returned_page_once
    tinkick_test_products(:red_apple).update!(name: "Mithril mithral unrelated")
    search = Product.search("mithril", misspellings: { edit_distance: 1 }, highlight: true, countless: true)
    statements = capture_queries do
      assert_equal [{ name: "<em>Mithril</em> <em>mithral</em> unrelated" }], search.highlights
      assert_equal search.highlights.first, search.to_a.first.search_highlights
    end
    assert_equal 1, statements.count { |sql| sql.include?("tin.highlight(") }
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_empty capture_queries { search.highlights }
  end

  def test_exact_first_decision_controls_the_native_highlight_query
    tinkick_test_products(:red_apple).update!(name: "mithril mithral")
    search = Product.search("mithril", misspellings: { edit_distance: 1, below: 1 }, highlight: true)

    assert_equal [{ name: "<em>mithril</em> mithral" }], search.highlights
    refute search.misspellings?
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
