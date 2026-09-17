# frozen_string_literal: true

require_relative "../integration_helper"

class QueryOptionsTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name, :description], default_fields: [:name]
  end

  class PhraseProduct < SearchProduct
    tinkick searchable: [:name], match: :phrase
  end

  def test_only_preserves_the_model_term_and_selected_options
    original = Product.search("apple", where: { name: "Green Pear" }, limit: 1, misspellings: false)
    selected = original.only(:limit, :misspellings)

    assert_same Product, selected.model
    refute selected.loaded?
    assert_equal 1, selected.limit_value
    assert_equal ["Red Apple"], selected.map(&:name)
    assert_empty original
    assert_equal 10_000, original.only.limit_value
    assert_equal ["Red Apple"], original.only.map(&:name)
  end

  def test_except_removes_query_options_without_mutating_a_loaded_search
    original = Product.search("*", where: { name: "Red Apple" }, limit: 1, order: :id).load
    changed = original.except(:where, :limit)

    refute changed.loaded?
    assert_equal 10_000, changed.limit_value
    assert_equal ["Red Apple", "Green Pear"], changed.map(&:name)
    assert_equal ["Red Apple"], original.map(&:name)
    assert_equal 1, original.limit_value
    refute original.except.loaded?
    assert_equal ["Red Apple"], original.except.map(&:name)
  end

  def test_removing_fields_restores_the_registered_default_fields
    original = Product.search("orchard", fields: [:description], misspellings: false)

    assert_equal ["Red Apple"], original.map(&:name)
    assert_empty original.except(:fields)
    assert_empty original.only(:misspellings)
    assert_equal ["Red Apple"], original.only(:fields, :misspellings).map(&:name)
  end

  def test_removing_match_restores_the_model_match_mode
    original = PhraseProduct.search("Apple Red", match: :word, misspellings: false)

    assert_equal ["Red Apple"], original.map(&:name)
    assert_empty original.except(:match)
    assert_empty original.only(:misspellings)
  end

  def test_removing_misspellings_restores_the_public_search_default
    original = Product.search("applf", misspellings: false)

    assert_empty original
    assert_equal ["Red Apple"], original.except(:misspellings).map(&:name)
    assert_equal ["Red Apple"], original.only.map(&:name)
  end

  def test_only_and_except_filter_options_rather_than_source_columns
    original = Product.search("*", where: { name: "Red Apple" }, load: false, select: :name)
    filtered = original.only(:where)
    raw = original.except(:select)

    assert_instance_of Product, filtered.first
    assert_equal "Fresh orchard fruit", filtered.first.description
    assert_instance_of Tinkick::HashWrapper, raw.first
    assert_equal Product.column_names.sort, raw.first.to_h.keys.sort
    assert_equal %w[id name], original.first.to_h.keys.sort
  end

  def test_unknown_and_string_keys_follow_searchkick_hash_option_semantics
    original = Product.search("*", limit: 1)

    assert_equal 10_000, original.only(:unknown).limit_value
    assert_equal 1, original.except(:unknown).limit_value
    assert_equal 10_000, original.only("limit").limit_value
    assert_equal 1, original.except("limit").limit_value
  end

  def test_removing_required_keyset_options_keeps_dependency_validation
    first = Product.search("*", keyset: true, limit: 1)
    second = Product.search("*", keyset: true, limit: 1, after: first.next_cursor)

    error = assert_raises(Tinkick::InvalidQueryError) { second.except(:keyset) }
    assert_includes error.message, "after requires keyset"
    assert_raises(Tinkick::InvalidQueryError) { second.only(:after) }
    assert_equal ["Red Apple"], second.except(:after).map(&:name)
    assert_equal ["Green Pear"], second.only(:keyset, :after, :limit).map(&:name)
  end
end
