# frozen_string_literal: true

require_relative "../integration_helper"

class ProjectionTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
    has_many :reviews, class_name: "ProjectionTest::Review", foreign_key: :product_id
  end

  class Review < ActiveRecord::Base
    self.table_name = "tinkick_test_reviews"
    belongs_to :product, class_name: "ProjectionTest::Product"
  end

  set_fixture_class(tinkick_test_reviews: Review)
  fixtures :tinkick_test_reviews

  def test_raw_source_projection_fetches_only_requested_columns_and_keeps_identity
    search = Product.search("apple", misspellings: false, load: false, select: :name)
    instantiated = []
    callback = ->(_name, _start, _finish, _id, payload) { instantiated << payload[:class_name] }
    statements = nil
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") do
      statements = capture_queries { search.load }
    end

    result = search.first
    assert_equal %w[id name], result.to_h.keys.sort
    assert_equal tinkick_test_products(:red_apple).id, result.id
    assert_equal "Red Apple", result.name
    refute result.respond_to?(:description)
    assert_empty instantiated
    projection = statements.find { |sql| sql.include?('FROM "tinkick_test_products"') }.split(" FROM ").first
    assert_includes projection, '"name"'
    refute_includes projection, '"description"'
    refute_includes projection, '"metadata"'
    refute_includes projection, ".*"
    assert_operator search.with_score.first.last, :>, 0
    assert_equal 1, search.total_count
  end

  def test_global_search_forwards_source_projection
    search = Tinkick.search("apple", model: Product, misspellings: false, load: false, select: :name)

    assert_equal %w[id name], search.first.to_h.keys.sort
    assert_equal "Red Apple", search.first.name
  end

  def test_arrays_and_complete_json_columns_preserve_their_values
    tinkick_test_products(:red_apple).update!(tags: ["red", "fresh"], metadata: { "origin" => { "country" => "Canada" } })
    result = Product.search("apple", misspellings: false, load: false, select: [:tags, :metadata]).first

    assert_equal %w[id metadata tags], result.to_h.keys.sort
    assert_equal ["red", "fresh"], result.tags
    assert_equal({ "origin" => { "country" => "Canada" } }, result.metadata)
  end

  def test_source_boolean_defaults_and_empty_selection_follow_searchkick
    [nil, true, false, {}, { includes: [] }].each do |selection|
      result = Product.search("*", load: false, select: selection, order: :id).first
      assert_equal Product.column_names.sort, result.to_h.keys.sort
    end
    assert_equal ["id"], Product.search("*", load: false, select: []).first.to_h.keys
  end

  def test_source_includes_and_excludes_accept_field_patterns_and_string_keys
    result = Product.search("*", load: false, select: { includes: ["d*", :name], excludes: :description }).first
    assert_equal %w[display_name id name], result.to_h.keys.sort

    result = Product.search("*", load: false, select: { "excludes" => ["d*", "id"] }).first
    assert_equal (Product.column_names - %w[description display_name]).sort, result.to_h.keys.sort
    assert result.respond_to?(:id)
  end

  def test_select_and_reselect_clone_append_and_replace_source_fields
    original = Product.search("*", load: false)
    named = original.select(:name)
    combined = named.select([:description])
    replaced = combined.reselect(:tags)

    assert_equal %w[id name], named.first.to_h.keys.sort
    assert_equal %w[description id name], combined.first.to_h.keys.sort
    assert_equal %w[id tags], replaced.first.to_h.keys.sort
    assert_equal Product.column_names.sort, original.first.to_h.keys.sort
    assert_equal ["id"], Product.search("*", load: false).select.first.to_h.keys
  end

  def test_bang_projection_methods_preserve_identity_and_guard_loaded_results
    search = Product.search("*", load: false)
    assert_same search, search.select!(:name)
    assert_same search, search.reselect!(:description)
    search.load
    assert_equal %w[description id], search.first.to_h.keys.sort
    assert_raises(Tinkick::Error) { search.select!(:name) }
    assert_raises(Tinkick::Error) { search.reselect!(:name) }
  end

  def test_block_select_is_enumerable_and_rejects_field_arguments
    search = Product.search("*", order: :id)
    selected = search.select { |product| product.name == "Green Pear" }
    assert_instance_of Array, selected
    assert_equal ["Green Pear"], selected.map(&:name)
    error = assert_raises(ArgumentError) { search.select(:name) { true } }
    assert_equal "wrong number of arguments (given 1, expected 0)", error.message
  end

  def test_model_loading_and_associations_keep_complete_attributes
    search = Product.search("apple", misspellings: false, select: [:name], includes: :reviews)
    result = search.first

    assert_instance_of Product, result
    assert_equal "Fresh orchard fruit", result.description
    assert result.association(:reviews).loaded?
    assert_empty capture_queries { assert_equal ["Crisp", "Juicy"], result.reviews.map(&:body).sort }
  end

  def test_projected_keyset_pages_keep_hidden_cursor_columns_without_exposing_them
    first_identifier = tinkick_test_products(:green_pear).id
    first = Product.search("*", load: false, select: :description, order: :name, keyset: true, limit: 1)
    statements = capture_queries do
      assert_equal [{ "id" => first_identifier, "description" => "Ripe fruit" }], first.map(&:to_h)
      assert first.has_next_page?
      refute_nil first.next_cursor
    end
    refute statements.any? { |sql| sql.match?(/COUNT\(/i) }
    assert_equal 1, statements.count { |sql| sql.start_with?("SELECT") }
    second = Product.search("*", load: false, select: :description, order: :name, keyset: true, limit: 1, after: first.next_cursor)
    assert_equal [tinkick_test_products(:red_apple).id], second.map(&:id)
    assert_equal %w[description id], second.first.to_h.keys.sort
    refute second.has_next_page?
    assert_nil second.next_cursor
    assert_equal 2, second.total_count
  end

  def test_raw_pluck_fetches_requested_columns_until_projection_is_loaded
    search = Product.search("apple", misspellings: false, load: false).select(:name)
    assert_equal ["Fresh orchard fruit"], search.pluck(:description)
    refute search.loaded?
    search.load
    assert_equal [nil], search.pluck(:description)
  end

  def test_unknown_and_sql_like_selectors_are_literal_source_patterns
    result = Product.search("*", load: false, select: ["missing", "name); DROP TABLE tinkick_test_products; --"]).first
    assert_equal ["id"], result.to_h.keys
    assert_equal 2, Product.count
  end

  def test_invalid_source_options_fail_with_actionable_errors
    [123, { invalid: [:name] }, { includes: [123] }].each do |selection|
      error = assert_raises(Tinkick::InvalidQueryError) { Product.search("*", load: false, select: selection).to_a }
      assert_includes error.message, "select"
    end
    error = assert_raises(Tinkick::InvalidQueryError) do
      Product.search("*", load: false, select: { excludes: :name }).select(:description)
    end
    assert_includes error.message, "reselect"
  end

  private

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
