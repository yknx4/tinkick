# frozen_string_literal: true

require_relative "test_helper"
require "active_record"

class ModelOptionsTest < Minitest::Test
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
end
