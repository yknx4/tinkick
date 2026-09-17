# frozen_string_literal: true

require_relative "../integration_helper"

class NestedProjectionTest < TinkickIntegrationTest
  class Product < SearchProduct
    tinkick searchable: [:name]
  end

  setup do
    @metadata = {
      "origin" => { "city" => "Rivendell", "secret" => "hidden", "active" => false, "note" => nil },
      "people" => [{ "name" => "Arwen", "role" => "ranger" }, { "role" => "smith" }, { "name" => "Gimli" }],
      "tags" => ["mithril", nil, false], "empty" => {}, "blank" => [],
      "origin.code" => "IML", "literal[0]" => "brackets", "new\nline" => "preserved",
    }
    tinkick_test_products(:red_apple).update!(metadata: @metadata)
  end

  def test_nested_paths_select_json_children_without_loading_other_columns
    statements = []
    listener = ->(*arguments) { statements << arguments.last[:sql] }
    row = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      row = search(select: ["metadata.origin.city", "metadata.origin.active", "metadata.origin.note"]).first
    end
    assert_equal({ "origin" => { "city" => "Rivendell", "active" => false, "note" => nil } }, row.metadata)
    assert_equal %w[id metadata], row.to_h.keys.sort
    projection = statements.find { |sql| sql.include?(" AS _tinkick_score") }.split(" FROM ").first
    assert_includes projection, '"metadata"'
    refute_includes projection, '"description"'
  end

  def test_array_children_keep_object_structure_and_drop_nonmatching_objects
    assert_equal({ "people" => [{ "name" => "Arwen" }, { "name" => "Gimli" }] }, search(select: "metadata.people.name").first.metadata)
    assert_equal({ "people" => [{ "name" => "Arwen" }, { "name" => "Gimli" }] }, search(select: { includes: "metadata.people", excludes: "metadata.people.role" }).first.metadata)
    assert_equal({ "tags" => ["mithril", nil, false] }, search(select: "metadata.tags").first.metadata)
  end

  def test_parent_selection_preserves_values_and_exclusions_take_precedence
    expected = @metadata.except("people").merge("origin" => @metadata.fetch("origin").except("secret"))
    assert_equal expected, search(select: { includes: "metadata", excludes: ["metadata.people", "*.secret"] }).first.metadata
    assert_equal ["id"], search(select: { includes: "metadata.origin.city", excludes: "metadata" }).first.to_h.keys
    assert_equal @metadata, search(select: "metadata").first.metadata
    assert_equal @metadata.except("origin", "origin.code"), search(select: { includes: "metadata", excludes: "metadata.origin" }).first.metadata
  end

  def test_wildcards_cross_object_boundaries_and_treat_punctuation_literally
    assert_equal({ "origin" => { "city" => "Rivendell" } }, search(select: "meta*city").first.metadata)
    assert_equal({ "literal[0]" => "brackets" }, search(select: "metadata.literal[0]").first.metadata)
    assert_equal({ "new\nline" => "preserved" }, search(select: "metadata.new*line").first.metadata)
    assert_equal({ "origin" => @metadata.fetch("origin"), "origin.code" => "IML" }, search(select: "metadata.origin").first.metadata)
  end

  def test_missing_descendants_do_not_invent_empty_objects
    assert_equal ["id"], search(select: "metadata.missing.child").first.to_h.keys
    assert_equal({ "empty" => {}, "blank" => [] }, search(select: ["metadata.empty", "metadata.blank"]).first.metadata)
    assert_equal({ "origin" => {} }, search(select: { includes: "metadata.origin", excludes: "metadata.origin.*" }).first.metadata)
  end

  def test_nonmatching_root_prefix_does_not_read_json_columns
    statements = []
    listener = ->(*arguments) { statements << arguments.last[:sql] }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      assert_equal ["id"], search(select: "metadatax.city").first.to_h.keys
    end
    projection = statements.find { |sql| sql.include?(" AS _tinkick_score") }.split(" FROM ").first
    refute_includes projection, '"metadata"'
  end

  def test_nested_source_pruning_warns_about_json_transfer_cost
    output = StringIO.new
    previous_logger = Product.logger
    Product.logger = Logger.new(output)
    search(select: "metadata.origin.city").to_a
    assert_includes output.string, "Large JSON values"
    assert_includes output.string, "bounded result page"
  ensure
    Product.logger = previous_logger
  end

  def test_nested_projection_preserves_cursor_identity_without_changing_model_loading
    first = Product.search("*", order: :name, keyset: true, limit: 1, load: false, select: "metadata.origin.city")
    assert first.has_next_page?
    second = Product.search("*", order: :name, keyset: true, limit: 1, load: false, select: "metadata.origin.city", after: first.next_cursor)
    assert_equal tinkick_test_products(:red_apple).id, second.first.id
    assert_equal %w[id metadata], second.first.to_h.keys.sort
    assert_equal @metadata, Product.search("apple", misspellings: false, select: "metadata.origin.city").first.metadata
    assert_equal @metadata, tinkick_test_products(:red_apple).reload.metadata
  end

  private

  def search(**options)
    Product.search("apple", misspellings: false, load: false, **options)
  end
end
