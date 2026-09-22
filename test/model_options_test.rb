# frozen_string_literal: true

require_relative "test_helper"
require "active_record"

class ModelOptionsTest < Minitest::Test
  def test_partial_mode_declarations_are_lazy_and_preserve_the_requested_fields
    [:word_start, :word_middle, :word_end, :text_start, :text_middle, :text_end].each do |mode|
      model = Class.new(ActiveRecord::Base)
      model.tinkick(**{ mode => [:name] })

      assert_equal [:name], model.tinkick_options.fetch(mode)
    end
  end

  def test_stemming_options_raise_an_unimplemented_error_identifying_tin
    [
      { stem: true },
      { language: "english" },
      { stemmer: { type: "hunspell", locale: "en_US" } },
      { stem_exclusion: ["business"] },
      { stemmer_override: ["axes => axe"] },
    ].each do |options|
      model = Class.new(ActiveRecord::Base)
      error = assert_raises(Tinkick::NotImplementedError) { model.tinkick(**options) }

      assert_kind_of Tinkick::Error, error
      assert_kind_of StandardError, error
      assert_includes error.message, options.keys.first.to_s
      assert_includes error.message, "not yet supported by TIN"
      assert_includes error.message, "migration"
      assert_nil model.tinkick_options
    end
  end

  def test_unknown_options_are_not_mislabeled_as_tin_limitations
    error = assert_raises(ArgumentError) { Class.new(ActiveRecord::Base).tinkick(typo: true) }

    assert_includes error.message, "typo"
    refute_includes error.message, "supported by TIN"
  end

  def test_stem_must_be_boolean
    [nil, "false", 1].each do |value|
      assert_raises(ArgumentError) { Class.new(ActiveRecord::Base).tinkick(stem: value) }
    end
  end

  def test_conversion_declarations_preserve_order_alias_precedence_and_disabled_values
    model = Class.new(ActiveRecord::Base)
    model.tinkick(conversions: :ignored, conversions_v1: [:clicks, "clicks", :views], conversions_v2: false)

    assert_equal ["clicks", "views"], model.tinkick_options.fetch(:conversions)
    assert_equal [], model.tinkick_options.fetch(:conversions_v2)
  end

  def test_declaration_validation_order_does_not_leave_partial_options
    cases = [
      [{ stem: nil, typo: true }, "stem must be true or false"],
      [{ conversions: [1], highlight: true }, "conversions must name JSONB columns with a string, symbol, or array; false or nil disables them"],
      [{ conversions: :clicks, conversions_v2: "clicks", highlight: true }, "A conversion column cannot be declared in both conversions and conversions_v2"],
      [{ highlight: true, word_start: false }, "highlight must be an array of field names, false, or nil"],
      [{ filterable: true, word_start: false }, "filterable must be an array of field names, false, or nil"],
      [{ word_start: false }, "Partial match declarations must be arrays of field names"],
    ]
    cases.each do |options, message|
      model = Class.new(ActiveRecord::Base)
      error = assert_raises(ArgumentError) { model.tinkick(**options) }
      assert_equal message, error.message
      assert_nil model.tinkick_options
    end
  end
end
