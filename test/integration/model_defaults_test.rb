# frozen_string_literal: true

require_relative "../integration_helper"
require "searchkick"

class ModelDefaultsTest < TinkickIntegrationTest
  setup do
    @previous = Tinkick.model_options if Tinkick.respond_to?(:model_options)
    @searchkick_options = Searchkick.model_options
    tinkick_test_products(:red_apple).update!(name: "Rivendell wizard", description: "Mithril lantern")
    tinkick_test_products(:green_pear).update!(name: "Pottery lesson", description: "Clay kiln")
  end

  teardown do
    Tinkick.model_options = @previous if Tinkick.respond_to?(:model_options=)
    Searchkick.model_options = @searchkick_options
  end

  def test_defaults_apply_to_each_model_declaration_and_preserve_query_overrides
    Tinkick.model_options = { searchable: [:name, :description], default_fields: [:description] }
    model = build_model

    assert_equal ["Rivendell wizard"], model.tinkick_search("mithril", misspellings: false).map(&:name)
    assert_empty model.tinkick_search("rivendell", misspellings: false)
    assert_equal ["Rivendell wizard"], model.tinkick_search("rivendell", fields: [:name], misspellings: false).map(&:name)
  end

  def test_explicit_model_values_override_global_values_including_nil_and_empty_arrays
    Tinkick.model_options = { searchable: [:description], default_fields: [:description], highlight: [:description], match: :phrase }
    model = build_model(searchable: [:name], default_fields: nil, highlight: [], match: :word)

    assert_equal ["Rivendell wizard"], model.tinkick_search("wizard rivendell", misspellings: false).map(&:name)
    assert_equal [], model.tinkick_options.fetch(:highlight)
    assert_nil model.tinkick_options.fetch(:default_fields)
    assert_equal [:description], Tinkick.model_options.fetch(:searchable)
    assert_equal :phrase, Tinkick.model_options.fetch(:match)
  end

  def test_explicit_false_overrides_a_global_unsupported_analysis_request
    Tinkick.model_options = { searchable: [:name], stem: true }
    error = assert_raises(Tinkick::NotImplementedError) { build_model }
    assert_includes error.message, "not yet supported by TIN"

    model = build_model(stem: false)
    assert_equal ["Rivendell wizard"], model.tinkick_search("rivendell", misspellings: false).map(&:name)
  end

  def test_later_configuration_changes_apply_to_new_declarations_only
    Tinkick.model_options = { searchable: [:name] }
    first = build_model
    Tinkick.model_options = { searchable: [:description] }
    second = build_model

    assert_equal ["Rivendell wizard"], first.tinkick_search("rivendell", misspellings: false).map(&:name)
    assert_empty second.tinkick_search("rivendell", misspellings: false)
    assert_equal ["Rivendell wizard"], second.tinkick_search("mithril", misspellings: false).map(&:name)
  end

  def test_searchkick_and_tinkick_defaults_remain_independent
    Searchkick.model_options = { searchable: [:description] }
    Tinkick.model_options = { searchable: [:name] }

    assert_equal ["Rivendell wizard"], build_model.tinkick_search("rivendell", misspellings: false).map(&:name)
    assert_equal({ searchable: [:description] }, Searchkick.model_options)
  end

  def test_invalid_global_options_are_validated_by_the_normal_declaration
    Tinkick.model_options = { unrecognized_option: true }
    error = assert_raises(ArgumentError) { build_model }

    assert_includes error.message, "unrecognized_option"
  end

  def test_global_defaults_do_not_connect_during_model_registration
    Tinkick.model_options = { searchable: [:name], highlight: [:name] }
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { build_model }

    assert_empty statements
  end

  private

  def build_model(**options)
    Class.new(SearchProduct) { tinkick(**options) }
  end
end
