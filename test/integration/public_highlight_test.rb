# frozen_string_literal: true

require_relative "../integration_helper"

class PublicHighlightTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description]
  end

  class ExistingHighlightProduct < SearchProduct
    tinkick searchable: [:name]

    def search_highlights
      { existing: "from the other search backend" }
    end
  end

  setup do
    tinkick_test_products(:red_apple).update!(name: "Gandalf visits Rivendell", description: "Rivendell welcomes the wizard")
    tinkick_test_products(:green_pear).update!(name: "Rivendell beneath the stars", description: "An unrelated pottery lesson")
  end

  def test_full_fields_hits_helpers_and_response_share_cached_highlights
    search = Product.search("rivendell", highlight: true, order: :name, misspellings: false)
    expected = { name: "Gandalf visits <em>Rivendell</em>", description: "<em>Rivendell</em> welcomes the wizard" }
    assert_equal expected, search.highlights.first
    assert_equal [expected[:name]], search.hits.first.fetch("highlight").fetch("name")
    assert_equal expected, search.to_a.first.search_highlights
    assert_equal expected, search.with_highlights.first.last
    assert_equal({ name: [expected[:name]], description: [expected[:description]] }, search.highlights(multiple: true).first)
    assert_equal search.highlights(multiple: true).first, search.with_highlights(multiple: true).first.last
    assert_same search.hits, search.response.fetch("hits").fetch("hits")
    assert_empty capture_queries {
                   search.highlights
                   search.with_highlights.to_a
                   search.to_a }
  end

  def test_tags_encoding_and_field_selection_work_through_fluent_options
    tinkick_test_products(:red_apple).update!(name: "<b>Rivendell</b>")
    original = Product.search("rivendell", misspellings: false, order: :name)
    search = original.highlight(fields: { name: {} }, tag: "<strong class='match'>", encoder: "html")

    assert_equal [{ name: "&lt;b&gt;<strong class='match'>Rivendell</strong>&lt;&#x2F;b&gt;" },
      { name: "<strong class='match'>Rivendell</strong> beneath the stars" }], search.highlights
    assert_equal [{}, {}], original.highlights
    assert_raises(Tinkick::Error) { search.highlight!(true) }
  end

  def test_scoped_results_keep_original_highlights_but_pair_only_visible_records
    search = Product.search("rivendell", fields: [:name], highlight: true, order: :name,
      scope_results: ->(scope) { scope.where(name: "Rivendell beneath the stars") })
    assert_equal 2, search.highlights.length
    pairs = search.with_highlights.to_a
    assert_equal ["Rivendell beneath the stars"], pairs.map { |record, _highlights| record.name }
    assert_equal [{ name: "<em>Rivendell</em> beneath the stars" }], pairs.map(&:last)
  end

  def test_raw_projection_keeps_highlight_inputs_hidden_and_never_counts
    search = Product.search("rivendell", fields: [:name], highlight: true, select: [], load: false,
      countless: true, limit: 1, order: :name)
    statements = capture_queries do
      row = search.to_a.first
      assert_equal "Gandalf visits <em>Rivendell</em>", row.highlighted_name
      assert_nil row["name"]
      refute search.hits.first.key?("_source")
      assert search.has_next_page?
    end
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_equal 1, statements.count { |sql| sql.include?(" AS _tinkick_score") }
    assert_equal 1, statements.count { |sql| sql.include?("tin.highlight(") }
    refute statements.find { |sql| sql.include?(" AS _tinkick_score") }.include?('"tinkick_test_products".*')
  end

  def test_phrase_partial_and_typo_queries_highlight_the_matching_source_tokens
    assert_equal "Gandalf <em>visits Rivendell</em>", Product.search("visits rivendell", fields: [:name],
      match: :phrase, misspellings: false, highlight: true).highlights.first[:name]
    assert_equal "Gandalf visits <em>Rivendell</em>", Product.search("vende", fields: [:name],
      match: :word_middle, misspellings: false, highlight: true, order: :name).highlights.first[:name]
    assert_equal "Gandalf visits <em>Rivendell</em>", Product.search("rivendll", fields: [:name],
      highlight: true, order: :name).highlights.first[:name]
  end

  def test_match_all_and_disabled_highlights_do_not_call_the_highlighter
    [true, false, nil].each do |option|
      search = Product.search("*", fields: [:name], highlight: option, load: false, order: :name)
      statements = capture_queries do
        assert_equal [{}, {}], search.highlights
        assert_equal "Gandalf visits Rivendell", search.to_a.first.highlighted_name if option
      end
      refute statements.any? { |sql| sql.include?("tin.highlight(") }
    end
    assert_equal({}, Product.search("*", highlight: true).to_a.first.search_highlights)
  end

  def test_existing_model_highlight_method_is_preserved
    record = ExistingHighlightProduct.search("rivendell", highlight: true).to_a.first
    assert_equal({ existing: "from the other search backend" }, record.search_highlights)
  end

  def test_json_inputs_stay_hidden_while_per_field_snippets_override_global_options
    title = "Rivendell beside the river #{'distant roads and hills ' * 8}Rivendell under the moon"
    tinkick_test_products(:red_apple).update!(metadata: { title: title, private_note: "do not include" })
    search = Tinkick.search("rivendell", model: Product, fields: ["metadata.title"],
      misspellings: false, load: false, select: [:name],
      highlight: { fragment_size: 0, fields: { "metadata.title" => { fragment_size: 25, number_of_fragments: 2 } } })

    fragments = search.highlights(multiple: true).first.fetch(:"metadata.title")
    assert_equal 2, fragments.length
    assert fragments.all? { |fragment| fragment.include?("<em>Rivendell</em>") }
    assert fragments.all? { |fragment| fragment.length < title.length }
    assert_equal ["name"], search.hits.first.fetch("_source").keys
    assert_nil search.to_a.first["metadata"]
    assert_equal fragments.first, search.to_a.first["highlighted_metadata.title"]
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
