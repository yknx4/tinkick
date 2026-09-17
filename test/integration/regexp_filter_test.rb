# frozen_string_literal: true

require_relative "../integration_helper"

class RegexpFilterTest < TinkickIntegrationTest
  def test_ruby_regexp_filters_explain_the_native_replacement
    error = assert_raises(Tinkick::NotImplementedError) do
      Tinkick::Filter.new(SearchProduct).apply(SearchProduct.all, name: /apple/i)
    end

    assert_includes error.message, "Ruby Regexp"
    assert_includes error.message, "PostgreSQL"
    assert_includes error.message, "regexp:"
  end

  def test_arrays_and_json_paths_do_not_translate_ruby_patterns
    [:tags, "metadata.title"].each do |field|
      assert_raises(Tinkick::NotImplementedError) do
        Tinkick::Filter.new(SearchProduct).apply(SearchProduct.all, field => /apple/)
      end
    end
  end

  def test_public_search_rejects_ruby_patterns_instead_of_ignoring_options
    model = Class.new(SearchProduct) { tinkick searchable: [:name] }

    assert_raises(Tinkick::NotImplementedError) do
      model.tinkick_search("*", where: { name: { regexp: /apple/i } }).to_a
    end
  end
end
