# frozen_string_literal: true

require_relative "../integration_helper"

class SearchMethodNameTest < TinkickIntegrationTest
  setup do
    @previous = Tinkick.search_method_name if Tinkick.respond_to?(:search_method_name)
    tinkick_test_products(:red_apple).update!(name: "Rivendell under starlight")
    tinkick_test_products(:green_pear).update!(name: "An unrelated pottery lesson")
  end

  teardown do
    Tinkick.search_method_name = @previous if Tinkick.respond_to?(:search_method_name=)
  end

  def test_custom_alias_searches_real_rows_and_leaves_generic_search_undefined
    Tinkick.search_method_name = :tin_search
    model = build_model

    assert_equal ["Rivendell under starlight"], model.tin_search("rivendell", misspellings: false).map(&:name)
    assert_equal model.tin_search("rivendell").map(&:id), model.tinkick_search("rivendell").map(&:id)
    refute_respond_to model, :search
  end

  def test_nil_disables_alias_creation_but_keeps_the_explicit_method
    Tinkick.search_method_name = nil
    model = build_model

    refute_respond_to model, :search
    assert_equal ["Rivendell under starlight"], model.tinkick_search("rivendell", misspellings: false).map(&:name)
  end

  def test_existing_public_private_and_protected_custom_methods_are_preserved
    Tinkick.search_method_name = :tin_search
    [:public, :private, :protected].each do |visibility|
      model = build_model do
        define_singleton_method(:tin_search) { :other_backend }
        singleton_class.send(visibility, :tin_search)
      end

      assert_equal :other_backend, model.send(:tin_search)
      assert_equal ["Rivendell under starlight"], model.tinkick_search("rivendell", misspellings: false).map(&:name)
    end
  end

  def test_string_aliases_and_inherited_methods_work_without_changing_registered_models
    Tinkick.search_method_name = "find_text"
    parent = build_model
    Tinkick.search_method_name = :later_search
    child = Class.new(parent)
    later = build_model

    assert_equal ["Rivendell under starlight"], child.find_text("rivendell", misspellings: false).map(&:name)
    refute_respond_to parent, :later_search
    assert_respond_to later, :later_search
    refute_respond_to later, :find_text
  end

  def test_declaration_with_a_custom_alias_remains_database_lazy
    Tinkick.search_method_name = :tin_search
    statements = []
    listener = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { build_model }

    assert_empty statements
  end

  private

  def build_model(&block)
    Class.new(SearchProduct) do
      class_eval(&block) if block
      tinkick searchable: [:name]
    end
  end
end
