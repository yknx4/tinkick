# frozen_string_literal: true

require_relative "test_helper"
require "searchkick"

class ResultsMetadataTest < Minitest::Test
  class Product < ActiveRecord::Base
    self.abstract_class = true
  end

  def setup
    @previous_backend = I18n.backend
    @previous_locale = I18n.locale
    @previous_locales = I18n.available_locales if I18n.config.available_locales_initialized?
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = [:en, :fr]
    I18n.locale = :en
  end

  def teardown
    I18n.backend = @previous_backend
    I18n.available_locales = @previous_locales
    I18n.locale = @previous_locale
  end

  def test_model_name_returns_the_actual_rails_name_without_searching
    assert_empty capture_queries {
      assert_same Product.model_name, results.model_name
      assert_same Product.model_name, relation.model_name
      assert_instance_of ActiveModel::Name, results.model_name
      assert_equal upstream.model_name.param_key, results.model_name.param_key
    }
  end

  def test_entry_name_matches_searchkick_default_and_count_fallbacks
    assert_equal "product", results.entry_name
    assert_equal "Product", results.entry_name(count: 1)
    assert_equal "Products", results.entry_name(count: 2)
    assert_equal "Products", results.entry_name(count: 0)
    [{}, { count: 1 }, { count: 2 }, { count: 0 }, { count: 2, default: "Items" }].each do |options|
      assert_equal upstream.entry_name(options), results.entry_name(options)
      assert_equal upstream.entry_name(options), relation.entry_name(options)
    end
  end

  def test_entry_name_matches_searchkick_translated_counts_and_locale_forms
    key = Product.model_name.i18n_key
    I18n.backend.store_translations(:en, activerecord: { models: { key => { one: "Library item", other: "Library items" } } })
    I18n.backend.store_translations(:fr, activerecord: { models: { key => { one: "Article", other: "Articles" } } })

    assert_equal "library item", results.entry_name
    assert_equal "Library items", results.entry_name(count: 2)
    assert_equal "Article", results.entry_name(locale: :fr, count: 1)
    assert_equal "Articles", results.entry_name(locale: "fr", count: 2)
    [{ locale: :fr }, { locale: :fr, count: 1 }, { locale: "fr", count: 2 }].each do |options|
      original = options.dup
      assert_equal upstream.entry_name(options), results.entry_name(options)
      assert_equal upstream.entry_name(options), relation.entry_name(options)
      assert_equal original, options
    end
    I18n.with_locale(:fr) { assert_equal upstream.entry_name, results.entry_name }
  end

  private

  def results
    Tinkick::Results.new(Tinkick::Query.new(Product, "*", fields: [:name]))
  end

  def relation
    Tinkick::Relation.new(Product, "*", fields: [:name], misspellings: false)
  end

  def upstream
    Searchkick::Results.new(Product, {})
  end

  def capture_queries
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end
end
