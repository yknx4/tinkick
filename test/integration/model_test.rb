# frozen_string_literal: true

require_relative "../../lib/tinkick/model"
require_relative "../integration_helper"
require "searchkick"

class ModelTest < TinkickIntegrationTest
  class RemoveDescriptionIndex < ActiveRecord::Migration[8.0]
    def change
      remove_index(:tinkick_test_products, :description, using: :tin)
    end
  end

  class SearchkickFirstProduct < SearchProduct
    searchkick(searchable: [:name], callbacks: false)
    extend Tinkick::Model
    tinkick(searchable: [:name])
  end

  class TinkickFirstProduct < SearchProduct
    extend Tinkick::Model
    tinkick(searchable: [:name])
    searchkick(searchable: [:name], callbacks: false)
  end

  def test_declaration_is_database_lazy
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      model = Class.new(ActiveRecord::Base)
      model.table_name = "tinkick_test_products"
      model.extend(Tinkick::Model)
      model.tinkick(searchable: [:name])
      assert_respond_to(model, :search)
    end
    assert_empty(statements)
  end

  def test_registered_model_searches_its_existing_rows
    model = search_model(searchable: [:name])
    search = model.search("apple", misspellings: false)

    assert_instance_of(Tinkick::Relation, search)
    assert_equal(["Red Apple"], search.map(&:name))
    assert_equal(1, search.total_count)
    assert_equal(["Red Apple"], model.tinkick_search("apple", misspellings: false).map(&:name))
  end

  def test_existing_search_method_is_preserved
    model = Class.new(SearchProduct) do
      define_singleton_method(:search) { :existing_search }
      extend Tinkick::Model
      tinkick(searchable: [:name])
    end

    assert_equal(:existing_search, model.search)
    assert_equal(["Red Apple"], model.tinkick_search("apple", misspellings: false).map(&:name))
  end

  def test_nonpublic_search_methods_are_preserved
    [:private, :protected].each do |visibility|
      model = Class.new(SearchProduct) do
        define_singleton_method(:search) { :existing_search }
        singleton_class.send(visibility, :search)
        extend Tinkick::Model
        tinkick(searchable: [:name])
      end

      assert_equal(:existing_search, model.send(:search))
      assert_equal(["Red Apple"], model.tinkick_search("apple", misspellings: false).map(&:name))
    end
  end

  def test_subclasses_inherit_registration
    parent = search_model(searchable: [:name])
    child = Class.new(parent)

    assert_equal(["Red Apple"], child.tinkick_search("apple", misspellings: false).map(&:name))
    assert_raises(ArgumentError) { child.tinkick(searchable: [:description]) }
  end

  def test_searchkick_and_tinkick_coexist_in_either_declaration_order
    [SearchkickFirstProduct, TinkickFirstProduct].each do |model|
      assert_instance_of(Searchkick::Relation, model.search("apple"))
      assert_instance_of(Searchkick::Relation, model.searchkick_search("apple"))
      assert_equal(["Red Apple"], model.tinkick_search("apple", misspellings: false).map(&:name))
    end
  end

  def test_search_called_on_an_active_record_relation_is_rejected
    model = search_model(searchable: [:name])
    error = assert_raises(Tinkick::Error) { model.where(name: "Red Apple").search("apple", misspellings: false) }
    assert_equal("search must be called on model, not relation", error.message)
  end

  def test_declaration_rejects_unknown_options_and_duplicate_registration
    model = search_model(searchable: [:name])
    assert_raises(ArgumentError) { model.tinkick(searchable: [:name]) }
    assert_raises(ArgumentError) { search_model(callbacks: false) }
  end

  def test_fields_follow_caller_then_defaults_then_searchable
    model = search_model(searchable: [:name, :description], default_fields: [:description])

    assert_equal(["Red Apple"], model.search("orchard", misspellings: false).map(&:name))
    assert_empty(model.search("apple", misspellings: false))
    assert_equal(["Red Apple"], model.search("apple", fields: [:name], misspellings: false).map(&:name))
    assert_empty(search_model(searchable: [:name]).search("orchard", misspellings: false))
  end

  def test_default_fields_come_from_text_columns
    assert_equal(["Red Apple"], search_model.search("orchard", misspellings: false).map(&:name))
  end

  def test_default_misspellings_uses_native_fuzzy_matching
    model = search_model(searchable: [:name])

    assert_equal(["Red Apple"], model.search("appl").map(&:name))
    assert_empty(model.search("appl", misspellings: false))
  end

  def test_model_match_option_can_be_overridden_per_query
    model = search_model(searchable: [:name], match: :phrase)

    assert_empty(model.search("apple red", misspellings: false))
    assert_equal(["Red Apple"], model.search("apple red", match: :word, misspellings: false).map(&:name))
  end

  def test_search_data_validates_symbol_and_string_keys_without_serializing_values
    model = search_model do
      define_method(:search_data) do
        { id: id, name: "a value that is never written", "description" => "also ignored" }
      end
    end

    assert_equal(["Red Apple"], model.search("apple", misspellings: false).map(&:name))
    assert_equal(["Red Apple"], model.search("orchard", misspellings: false).map(&:name))
    assert_empty(model.search("never written", misspellings: false))
  end

  def test_search_data_works_for_an_empty_table
    SearchProduct.delete_all
    model = search_model do
      define_method(:search_data) { { name: name } }
    end

    assert_empty(model.search("apple", misspellings: false))
  end

  def test_missing_search_data_fields_explain_required_migrations
    model = search_model(searchable: [:name]) do
      define_method(:search_data) { { name: name, missing_computed_name: "computed", other_missing_field: nil } }
    end

    error = assert_raises(Tinkick::MissingFieldError) { model.search("apple", misspellings: false) }
    assert_match(/missing_computed_name/, error.message)
    assert_match(/other_missing_field/, error.message)
    assert_match(/Rails migration/, error.message)
    assert_match(/persisted or generated columns/, error.message)
    assert_match(/not persisted/, error.message)
  end

  def test_generated_column_is_used_instead_of_ruby_search_data_value
    model = search_model do
      define_method(:search_data) { { display_name: "ignored Ruby value" } }
    end

    assert_equal(["Red Apple"], model.search("apple orchard", misspellings: false).map(&:name))
    assert_empty(model.search("ignored Ruby", misspellings: false))
  end

  def test_search_data_requiring_persisted_values_fails_clearly
    model = search_model do
      define_method(:search_data) { { name: name.upcase } }
    end

    error = assert_raises(Tinkick::Error) { model.search("apple", misspellings: false) }
    assert_match(/search_data.*new instance/, error.message)
    assert_match(/persisted or generated columns/, error.message)
  end

  def test_search_data_requiring_an_association_fails_clearly
    model = search_model do
      belongs_to :linked_product, class_name: "SearchProduct", foreign_key: :id, optional: true
      define_method(:search_data) { { name: linked_product.name } }
    end

    error = assert_raises(Tinkick::Error) { model.search("apple", misspellings: false) }
    assert_match(/search_data.*new instance/, error.message)
  end

  def test_search_data_must_return_a_hash
    model = search_model do
      define_method(:search_data) { nil }
    end

    error = assert_raises(Tinkick::Error) { model.search("apple", misspellings: false) }
    assert_match(/search_data must return a Hash/, error.message)
  end

  def test_query_fields_must_exist_and_have_searchable_types
    model = search_model(searchable: [:name])
    error = assert_raises(Tinkick::MissingFieldError) { model.search("apple", fields: [:missing], misspellings: false) }
    assert_match(/missing.*Rails migration/, error.message)
    error = assert_raises(Tinkick::InvalidQueryError) { model.search("1", fields: [:id], misspellings: false) }
    assert_match(/text or citext/, error.message)
  end

  def test_validation_is_cached_until_active_record_schema_refresh
    model = search_model(searchable: [:name]) do
      class_attribute :validated_records, default: []
      define_method(:search_data) do
        self.class.validated_records << new_record?
        { name: name }
      end
    end
    model.search("apple", misspellings: false)
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      model.search("pear", misspellings: false)
      model.search("orchard", fields: [:description], misspellings: false)
    end
    assert_empty(statements)
    assert_equal([true], model.validated_records)

    model.reset_column_information
    model.search("apple", misspellings: false)
    assert_equal([true, true], model.validated_records)
  end

  def test_missing_index_fails_after_schema_refresh_and_a_migration_resolves_it
    model = search_model(searchable: [:description])
    model.search("orchard", misspellings: false)
    migration = RemoveDescriptionIndex.new
    migration.migrate(:up)
    begin
      model.reset_column_information
      error = assert_raises(Tinkick::Error) { model.search("orchard", misspellings: false) }
      assert_match(/description.*TIN index/, error.message)
      assert_match(/Rails migration.*add_index.*using: :tin/, error.message)
    ensure
      migration.migrate(:down)
      model.reset_column_information
    end

    assert_equal(["Red Apple"], model.search("orchard", misspellings: false).map(&:name))
  end

  private

  def search_model(**options, &block)
    Class.new(SearchProduct) do
      extend Tinkick::Model
      class_eval(&block) if block
      tinkick(**options)
    end
  end
end
