# frozen_string_literal: true

require_relative "../integration_helper"
require "stringio"

class WarningsTest < TinkickIntegrationTest
  def test_disabling_warnings_preserves_real_search_results_and_validation_errors
    original_logger = SearchProduct.logger
    original_warnings = Tinkick.warnings
    output = StringIO.new
    SearchProduct.logger = Logger.new(output)
    model = Class.new(SearchProduct) do
      tinkick searchable: [:name, :description]
    end

    Tinkick.warnings = true
    expected = model.tinkick_search("fruit", misspellings: false, offset: 1, load: false).map(&:id)
    assert_equal 1, expected.length
    assert_match "load: false", output.string
    assert_match "offset pagination", output.string
    assert_match "multiple fields", output.string

    output.truncate(0)
    output.rewind
    Tinkick.warnings = false
    actual = model.tinkick_search("fruit", misspellings: false, offset: 1).load(false).map(&:id)
    assert_equal expected, actual
    refute_match "Tinkick:", output.string
    assert_raises(Tinkick::MissingFieldError) { model.tinkick_search("fruit", fields: [:missing_column]) }
  ensure
    SearchProduct.logger = original_logger
    Tinkick.warnings = original_warnings
  end
end
