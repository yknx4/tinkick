# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/model"

class WildcardFieldsTest < TinkickIntegrationTest
  def test_star_uses_searchable_fields_independently_of_default_fields
    model = Class.new(SearchProduct) { tinkick searchable: [:name, :description], default_fields: [:name] }

    assert_empty(model.search("orchard", misspellings: false))
    assert_equal(["Red Apple"], model.search("orchard", fields: ["*"], misspellings: false).map(&:name))
  end

  def test_star_can_be_the_default_field_selection
    model = Class.new(SearchProduct) { tinkick searchable: [:name, :description], default_fields: ["*"] }

    assert_equal(["Red Apple"], model.search("orchard", misspellings: false).map(&:name))
  end

  def test_fluent_fields_expand_without_changing_the_original_relation
    model = Class.new(SearchProduct) { tinkick searchable: [:name, :description], default_fields: [:name] }
    original = model.search("orchard", misspellings: false)
    expanded = original.fields("*")

    assert_empty(original)
    assert_equal(["Red Apple"], expanded.map(&:name))
    refute_same(original, expanded)
  end

  def test_inferred_star_respects_search_data_column_keys
    model = Class.new(SearchProduct) do
      tinkick default_fields: [:name]
      def search_data
        { name: name, description: description }
      end
    end

    statements = capture_queries do
      assert_equal(["Red Apple"], model.search("orchard", fields: ["*"], misspellings: false).map(&:name))
    end
    query = statements.find { |sql| sql.include?(" AS _tinkick_score") }
    assert_includes(query, '"description" ==>')
    refute_includes(query, '"display_name" ==>')
    refute_includes(query, '"metadata" ==>')
  end

  def test_leading_star_dot_matches_only_declared_indexed_json_paths
    apple = tinkick_test_products(:red_apple)
    pear = tinkick_test_products(:green_pear)
    apple.update!(metadata: { title: "Orchard", details: { title: "Ruby history" } })
    pear.update!(metadata: { title: "Ruby garden", other: { title: "Orchard" } })
    model = Class.new(SearchProduct) do
      tinkick searchable: [:name, "metadata.title", "metadata.details.title"], default_fields: [:name]
    end

    assert_equal([apple.id], model.search("orchard", fields: ["*.title"], misspellings: false).map(&:id))
    assert_equal([apple.id, pear.id].sort, model.search("ruby", fields: ["*.title"], misspellings: false).map(&:id).sort)
    assert_equal([apple.id], model.search("history", fields: ["*.details.*"], misspellings: false).map(&:id))
  end

  def test_wildcard_field_hash_preserves_phrase_mode
    model = Class.new(SearchProduct) { tinkick searchable: [:name, :description] }

    assert_equal(["Red Apple"], model.search("fresh orchard", fields: [{ "*" => :phrase }], misspellings: false).map(&:name))
    assert_empty(model.search("orchard fresh", fields: [{ "*" => :phrase }], misspellings: false))
  end

  def test_partial_wildcards_only_expand_fields_with_that_mode_declared
    model = Class.new(SearchProduct) do
      tinkick searchable: [:name, :description], word_start: [:name]
    end

    assert_equal(["Red Apple"], model.search("app", fields: [{ "*" => :word_start }], misspellings: false).map(&:name))
    assert_empty(model.search("orch", fields: [{ "*" => :word_start }], misspellings: false))
    undeclared = Class.new(SearchProduct) { tinkick searchable: [:name] }
    assert_empty(undeclared.search("app", fields: [{ "*" => :word_start }], misspellings: false))
  end

  def test_default_partial_match_maps_all_known_fields_but_no_analyzed_fields
    model = Class.new(SearchProduct) do
      tinkick searchable: [:name, :description], default_fields: ["*"], match: :word_start
    end

    assert_equal(["Red Apple"], model.search("orch", misspellings: false).map(&:name))
    assert_empty(model.search("orchard", fields: [{ "*" => :word }], misspellings: false))
    inferred = Class.new(SearchProduct) { tinkick default_fields: ["*"], match: :word_start }
    assert_equal(["Red Apple"], inferred.search("orch", misspellings: false).map(&:name))
  end

  def test_exact_wildcards_remain_literal_keyword_fields
    model = Class.new(SearchProduct) { tinkick searchable: [:name] }

    assert_raises(Tinkick::MissingFieldError) do
      model.search("Red Apple", fields: [{ "*" => :exact }], misspellings: false)
    end
  end

  def test_unmatched_pattern_has_no_lexical_matches_but_keeps_match_all_semantics
    model = Class.new(SearchProduct) { tinkick searchable: [:name] }
    search = model.search("apple", fields: ["*.absent"], misspellings: false)

    assert_empty(search)
    assert_equal(0, search.total_count)
    assert_equal(SearchProduct.count, model.search("*", fields: ["*.absent"]).total_count)
    assert_raises(ArgumentError) { model.search("apple", fields: [], misspellings: false) }
  end

  def test_arbitrary_prefix_patterns_remain_literal_fields
    model = Class.new(SearchProduct) { tinkick searchable: [:name] }

    assert_raises(Tinkick::MissingFieldError) { model.search("apple", fields: ["na*"], misspellings: false) }
  end

  def test_expanded_json_fields_still_require_their_expression_indexes
    model = Class.new(SearchProduct) { tinkick searchable: ["metadata.unindexed"], default_fields: ["*.unindexed"] }
    error = assert_raises(Tinkick::Error) { model.search("orchard", misspellings: false) }

    assert_includes(error.message, "metadata.unindexed")
    assert_includes(error.message, "TIN expression index")
    assert_includes(error.message, "tinkick:index")
  end

  def test_per_field_misspellings_can_select_the_original_star
    model = Class.new(SearchProduct) { tinkick searchable: [:name, :description] }

    assert_equal(["Red Apple"], model.search("applf", fields: ["*"], misspellings: { fields: ["*"] }).map(&:name))
    assert_empty(model.search("applf", fields: ["*"], misspellings: { fields: [] }))
  end

  def test_per_field_misspellings_can_select_the_original_json_pattern
    apple = tinkick_test_products(:red_apple)
    apple.update!(metadata: { title: "Rivendell" })
    model = Class.new(SearchProduct) { tinkick searchable: [:name, "metadata.title"] }

    assert_equal([apple.id], model.search("rivendelk", fields: ["*.title"], misspellings: { fields: ["*.title"] }).map(&:id))
  end

  def test_per_field_misspellings_cannot_select_an_unrequested_selector
    model = Class.new(SearchProduct) { tinkick searchable: [:name] }

    ["*.title", "name"].each do |field|
      error = assert_raises(ArgumentError) do
        model.search("applf", fields: ["*"], misspellings: { fields: [field] })
      end
      assert_includes(error.message, "must also be specified in fields option")
    end
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
