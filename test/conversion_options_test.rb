# frozen_string_literal: true

require_relative "test_helper"
require "active_record"

class ConversionOptionsTest < Minitest::Test
  def setup
    @models = Tinkick.models.dup
    @defaults = Tinkick.model_options
  end

  def teardown
    Tinkick.models = @models
    Tinkick.model_options = @defaults
  end

  def test_declares_literal_column_names_without_a_database_connection
    model = Class.new(ActiveRecord::Base)
    statements = []
    callback = ->(*arguments) { statements << arguments.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      model.tinkick conversions: [:purchases, "purchases"], conversions_v2: :clicks
    end

    assert_equal ["purchases"], model.tinkick_options.fetch(:conversions)
    assert_equal ["clicks"], model.tinkick_options.fetch(:conversions_v2)
    assert_empty statements
  end

  def test_v1_alias_takes_precedence_including_explicit_nil
    model = Class.new(ActiveRecord::Base)
    model.tinkick conversions: :ignored, conversions_v1: :purchases
    assert_equal ["purchases"], model.tinkick_options.fetch(:conversions)

    disabled = Class.new(ActiveRecord::Base)
    disabled.tinkick conversions: :ignored, conversions_v1: nil
    assert_empty disabled.tinkick_options.fetch(:conversions)
  end

  def test_global_defaults_and_explicit_disabling
    Tinkick.model_options = { conversions: :purchases, conversions_v2: [:clicks] }
    model = Class.new(ActiveRecord::Base)
    model.tinkick
    assert_equal ["purchases"], model.tinkick_options.fetch(:conversions)
    assert_equal ["clicks"], model.tinkick_options.fetch(:conversions_v2)

    disabled = Class.new(ActiveRecord::Base)
    disabled.tinkick conversions: false, conversions_v2: []
    assert_empty disabled.tinkick_options.fetch(:conversions)
    assert_empty disabled.tinkick_options.fetch(:conversions_v2)
  end

  def test_invalid_and_overlapping_declarations_fail_before_registration
    [{ conversions: true }, { conversions_v2: [1] }, { conversions: { field: :counts } },
     { conversions: :counts, conversions_v2: "counts" }].each do |options|
      model = Class.new(ActiveRecord::Base)
      assert_raises(ArgumentError) { model.tinkick(**options) }
      assert_nil model.tinkick_options
      refute_includes Tinkick.models, model
    end
  end

  def test_conversion_stemming_has_an_actionable_native_limit
    model = Class.new(ActiveRecord::Base)
    error = assert_raises(Tinkick::NotImplementedError) do
      model.tinkick conversions: :purchases, stem_conversions: true
    end
    assert_includes error.message, "not yet supported by TIN"
    assert_includes error.message, "JSONB"
    assert_nil model.tinkick_options
    model.tinkick conversions: :purchases, stem_conversions: false
    assert_equal ["purchases"], model.tinkick_options.fetch(:conversions)
  end
end
