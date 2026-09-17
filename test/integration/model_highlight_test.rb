# frozen_string_literal: true

require_relative "../integration_helper"

class ModelHighlightTest < TinkickIntegrationTest
  setup do
    tinkick_test_products(:red_apple).update!(name: "Rivendell", description: "Rivendell beside the river")
    tinkick_test_products(:green_pear).update!(name: "Distant pottery", description: "An unrelated lesson")
  end

  def test_declaration_retains_fields_but_does_not_automatically_highlight_queries
    model = build_model(highlight: [:name])

    assert_equal [:name], model.tinkick_options.fetch(:highlight)
    assert_equal [{}], model.tinkick_search("rivendell", misspellings: false).highlights
    assert_equal [{ name: "<em>Rivendell</em>", description: "<em>Rivendell</em> beside the river" }],
      model.tinkick_search("rivendell", misspellings: false, highlight: true).highlights
  end

  def test_unlisted_fields_can_still_highlight_without_an_extra_index_or_extension
    [[], false].each do |declaration|
      model = build_model(highlight: declaration)
      results = model.tinkick_search("rivendell", misspellings: false, highlight: { fields: { description: {} } })

      assert_equal [{ description: "<em>Rivendell</em> beside the river" }], results.highlights
    end
  end

  def test_missing_declared_fields_raise_a_migration_error_when_search_is_used
    model = build_model(highlight: [:name, :search_title])
    error = assert_raises(Tinkick::MissingFieldError) { model.tinkick_search("rivendell") }

    assert_includes error.message, "search_title"
    assert_includes error.message, "Rails migration"
  end

  def test_declaration_is_database_lazy_and_inherited
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    model = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { model = build_model(highlight: ["name"]) }

    assert_empty statements
    child = Class.new(model)
    assert_equal ["name"], child.tinkick_options.fetch(:highlight)
    assert_equal [{ name: "<em>Rivendell</em>" }], child.tinkick_search("rivendell", fields: [:name],
      highlight: true, misspellings: false).highlights
  end

  def test_declaration_rejects_invalid_field_lists
    [true, "name", { name: {} }, [42]].each do |value|
      error = assert_raises(ArgumentError) { build_model(highlight: value) }
      assert_match(/highlight.*array.*field/i, error.message)
    end
  end

  private

  def build_model(**options)
    Class.new(SearchProduct) do
      tinkick searchable: [:name, :description], **options
    end
  end
end
