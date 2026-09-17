# frozen_string_literal: true

require_relative "../integration_helper"

class SqlHighlightTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  def test_sql_modes_highlight_the_entire_eligible_field
    tinkick_test_products(:red_apple).update!(name: "Rivendell under the stars")
    { exact: "Rivendell under the stars", text_start: "rivendell", text_middle: "under", text_end: "stars" }.each do |mode, term|
      search = Product.search(term, fields: [{ name: mode }], misspellings: false, highlight: true)
      assert_equal [{ name: "<em>Rivendell under the stars</em>" }], search.highlights, mode.to_s
    end
  end

  def test_fields_are_checked_independently_when_a_different_field_matches
    tinkick_test_products(:red_apple).update!(name: "Rivendell", description: "A pottery lesson")
    tinkick_test_products(:green_pear).update!(name: "Travel to Rivendell", description: "Rivendell at dawn")
    search = Product.search("Rivendell", fields: [{ name: :exact }, :description], misspellings: false,
      order: :name, highlight: true)
    assert_equal [{ name: "<em>Rivendell</em>" }, { description: "<em>Rivendell</em> at dawn" }], search.highlights
  end

  def test_sql_fuzzy_highlights_reuse_the_whole_field_match_rules
    tinkick_test_products(:red_apple).update!(name: "pineapple orchard")
    search = Product.search("papel", fields: [{ name: :text_middle }],
      misspellings: { edit_distance: 2 }, highlight: true)
    assert_equal [{ name: "<em>pineapple orchard</em>" }], search.highlights
  end

  def test_complete_match_spans_survive_small_snippet_sizes_and_html_encoding
    tinkick_test_products(:red_apple).update!(name: "<b>Rivendell</b>")
    search = Product.search("rivendell", fields: [{ name: :text_middle }], misspellings: false,
      load: false, select: [], highlight: { encoder: "html", tag: "<mark>", fragment_size: 3 })
    assert_equal [{ name: ["<mark>&lt;b&gt;Rivendell&lt;&#x2F;b&gt;</mark>"] }], search.highlights(multiple: true)
    assert_nil search.to_a.first["name"]
    refute search.hits.first.key?("_source")
  end
end
