# frozen_string_literal: true

require_relative "test_helper"
require "active_record"
require "searchkick"

class ModelRegistryTest < Minitest::Test
  def setup
    @original_models = Tinkick.models
    @original_searchkick_models = Searchkick.models
    Tinkick.models = []
    Searchkick.models = []
    @product = self.class.const_set(:Product, Class.new(ActiveRecord::Base))
    @product.table_name = "tinkick_registry_products"
  end

  def teardown
    Tinkick.models = @original_models if @original_models
    Searchkick.models = @original_searchkick_models if @original_searchkick_models
    self.class.send(:remove_const, :Product) if self.class.const_defined?(:Product, false)
  end

  def test_registers_only_successful_declarations_without_database_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }

    assert_empty Tinkick.models
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      @product.tinkick searchable: [:name]
    end
    assert_equal [@product], Tinkick.models
    assert_empty statements
    assert_raises(ArgumentError) { @product.tinkick searchable: [:description] }
    assert_equal [@product], Tinkick.models
  end

  def test_invalid_declarations_do_not_add_registry_entries
    assert_raises(ArgumentError) { @product.tinkick filterable: "name" }
    assert_empty Tinkick.models

    @product.tinkick searchable: [:name]
    assert_equal [@product], Tinkick.models
  end

  def test_inherited_registration_does_not_duplicate_the_declaring_model
    @product.tinkick searchable: [:name]
    child = Class.new(@product)

    assert_equal @product.tinkick_options, child.tinkick_options
    assert_equal [@product], Tinkick.models
    assert_raises(ArgumentError) { child.tinkick searchable: [:name] }
    assert_equal [@product], Tinkick.models
  end

  def test_registry_is_independent_from_searchkick_in_both_declaration_orders
    @product.searchkick searchable: [:name], callbacks: false
    assert_empty Tinkick.models
    @product.tinkick searchable: [:name]
    assert_equal [@product], Tinkick.models
    assert_equal [@product], Searchkick.models
    refute_same Tinkick.models, Searchkick.models

    another = self.class.const_set(:OtherProduct, Class.new(ActiveRecord::Base))
    another.table_name = "tinkick_registry_products"
    another.tinkick searchable: [:name]
    assert_equal [@product], Searchkick.models
    another.searchkick searchable: [:name], callbacks: false
    assert_equal [@product, another], Tinkick.models
    assert_equal [@product, another], Searchkick.models
  ensure
    self.class.send(:remove_const, :OtherProduct) if self.class.const_defined?(:OtherProduct, false)
  end
end
