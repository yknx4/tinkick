# frozen_string_literal: true

require_relative "../integration_helper"

class RawRegexpEnumProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  enum :description, { public: "P", preview: "P", archived: "A", absent: nil },
    scopes: false, instance_methods: false
end

class RawRegexpFilterTest < TinkickIntegrationTest
  setup do
    SearchProduct.delete_all
    ["Moria", "Moria gate", "Gondor", "apple", "club", "ab", "", "a😀b"].each_with_index do |name, index|
      SearchProduct.create!(id: index + 1, name: name, description: "travel archive",
        tags: [name], metadata: { titles: [name] })
    end
  end

  def test_raw_strings_match_the_entire_value_without_ruby_substring_wrapping
    assert_equal [1], filtered(name: { regexp: "Moria" }).ids
    assert_equal [1, 2], filtered(name: { regexp: "Moria.*" }).order(:id).ids
    assert_empty filtered(name: { regexp: "moria.*" })
    assert_equal [1, 2], filtered(name: /Moria/).order(:id).ids
    assert_equal [7], filtered(name: { regexp: "" }).ids
  end

  def test_optional_operators_compose_with_native_search_and_boolean_conditions
    assert_equal [6, 8], filtered(name: { regexp: "a.*&.*b" }).order(:id).ids
    assert_equal [8], filtered(name: { regexp: "a(~\"\")b" }).ids
    assert_equal [2], filtered(_and: [{ name: { regexp: "Moria@" } }, { _not: { name: { regexp: "Moria" } } }]).ids
    assert_empty filtered(name: { regexp: "@" }, description: "unrelated atlas")
  end

  def test_array_operators_match_one_element_and_preserve_negation
    SearchProduct.find(1).update!(tags: ["apple", "club"])
    SearchProduct.find(2).update!(tags: [nil, "ab"])
    SearchProduct.find(3).update!(tags: nil)
    scope = SearchProduct.where(id: [1, 2, 3])
    compiler = Tinkick::Filter.new(SearchProduct)

    assert_equal [2], compiler.apply(scope, tags: { regexp: "a.*&.*b" }).ids
    assert_equal [1, 3], compiler.apply(scope, _not: { tags: { regexp: "a.*&.*b" } }).order(:id).ids
    assert_equal [1, 2], compiler.apply(scope, tags: { regexp: "@" }).order(:id).ids
  end

  def test_json_paths_keep_recursive_elements_separate_and_ignore_non_strings
    SearchProduct.find(1).update!(metadata: { titles: [["apple"], ["club"]], unrelated: "ab" })
    SearchProduct.find(2).update!(metadata: { titles: [[nil, "ab"]] })
    SearchProduct.find(3).update!(metadata: { titles: [123, nil, true] })
    compiler = Tinkick::Filter.new(SearchProduct)
    scope = SearchProduct.where(id: [1, 2, 3])

    assert_equal [2], compiler.apply(scope, "metadata.titles" => { regexp: "a.*&.*b" }).ids
    assert_equal [1, 2], compiler.apply(scope, "metadata.titles" => { regexp: "@" }).order(:id).ids
    assert_equal [1, 3], compiler.apply(scope, _not: { "metadata.titles" => { regexp: "a.*&.*b" } }).order(:id).ids
  end

  def test_enum_patterns_use_canonical_labels_including_null_backings
    SearchProduct.find(1).update!(description: "P")
    SearchProduct.find(2).update!(description: "A")
    SearchProduct.find(3).update!(description: nil)
    SearchProduct.find(4).update!(description: "REMOVED")
    scope = RawRegexpEnumProduct.where(id: [1, 2, 3, 4])
    compiler = Tinkick::Filter.new(RawRegexpEnumProduct)

    assert_equal [1], compiler.apply(scope, description: { regexp: "p.*&.*c" }).ids
    assert_empty compiler.apply(scope, description: { regexp: "preview" })
    assert_equal [3], compiler.apply(scope, description: { regexp: "@&~(public|archived)" }).ids
    assert_equal [1, 2, 3], compiler.apply(scope, description: { regexp: "@" }).order(:id).ids
  end

  def test_public_search_supports_countless_pages_and_exact_totals
    model = Class.new(SearchProduct) { tinkick searchable: [:description] }
    query = model.tinkick_search("archive", misspellings: false,
      where: { name: { regexp: "Moria@" } }, order: { id: :asc }, limit: 1)

    assert_equal [1], query.map(&:id)
    assert_equal 2, query.total_count
    countless = query.countless
    assert_equal [1], countless.map(&:id)
    assert countless.has_next_page?
    refute countless.response.fetch("hits").key?("total")
  end

  def test_bound_pattern_values_cannot_change_the_query
    SearchProduct.find(1).update!(name: "x' OR TRUE --z")

    assert_equal [1], filtered(name: { regexp: "x(' OR TRUE --)@z" }).ids
    assert_empty filtered(name: { regexp: "x(' OR TRUE --)@z" }, id: 2)
    assert_raises(Tinkick::InvalidQueryError) { filtered(name: { regexp: "a&" }) }
    [nil, 1, ["Moria"]].each do |value|
      assert_raises(TypeError) { filtered(name: { regexp: value }) }
    end
  end

  private

  def filtered(conditions)
    Tinkick::Filter.new(SearchProduct).apply(SearchProduct.where("description ==> ?", "archive"), conditions)
  end
end
