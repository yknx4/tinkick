# frozen_string_literal: true

require_relative "../integration_helper"

class ModelFilterableTest < TinkickIntegrationTest
  setup do
    @previous = Tinkick.model_options
    @forge = tinkick_test_products(:red_apple)
    @archive = tinkick_test_products(:green_pear)
    @forge.update!(name: "Moria forge", metadata: { kind: "forge", rating: 3 })
    @archive.update!(name: "Rivendell archive", metadata: { kind: "library", rating: 9 })
  end

  teardown do
    Tinkick.model_options = @previous
  end

  def test_declared_scalar_and_jsonb_filters_use_columns_without_tin_indexes
    model = build_model(filterable: [:id, "metadata.rating"])

    assert_equal [@archive.id], model.tinkick_search("forge archive", operator: :or,
      misspellings: false, where: { "metadata.rating" => { gte: 5 } }).map(&:id)
    assert_equal [@forge.id], model.tinkick_search("forge", misspellings: false,
      where: { id: @forge.id }).map(&:id)
  end

  def test_declarations_do_not_restrict_filters_to_listed_fields
    [[], false, nil, ["metadata.kind"]].each do |fields|
      model = build_model(filterable: fields)

      assert_equal [@forge.id], model.tinkick_search("*", where: { id: @forge.id }).map(&:id)
    end
  end

  def test_missing_columns_and_invalid_jsonb_roots_explain_required_migrations
    model = build_model(filterable: [:search_category])
    error = assert_raises(Tinkick::MissingFieldError) { model.tinkick_search("forge") }
    assert_includes error.message, "search_category"
    assert_includes error.message, "Rails migration"

    model = build_model(filterable: ["name.category"])
    error = assert_raises(Tinkick::InvalidQueryError) { model.tinkick_search("forge") }
    assert_includes error.message, "JSONB"
    assert_includes error.message, "Rails migration"
  end

  def test_registration_is_lazy_and_the_declaration_is_inherited
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    model = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      model = build_model(filterable: ["metadata.kind"])
    end

    assert_empty statements
    assert_equal [@archive.id], Class.new(model).tinkick_search("archive", misspellings: false,
      where: { "metadata.kind" => "library" }).map(&:id)
  end

  def test_global_defaults_and_explicit_overrides_use_the_same_validation
    Tinkick.model_options = { filterable: [:missing_category] }
    assert_raises(Tinkick::MissingFieldError) { build_model.tinkick_search("forge") }
    assert_equal [@forge.id], build_model(filterable: []).tinkick_search("forge", misspellings: false).map(&:id)

    [true, "name", { name: {} }, [42]].each do |value|
      error = assert_raises(ArgumentError) { build_model(filterable: value) }
      assert_match(/filterable.*array.*field/i, error.message)
    end
  end

  private

  def build_model(**options)
    Class.new(SearchProduct) { tinkick searchable: [:name], **options }
  end
end
