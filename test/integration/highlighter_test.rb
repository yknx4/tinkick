# frozen_string_literal: true

require_relative "../test_helper"
require "tinkick/highlighter"
require_relative "../integration_helper"

class HighlighterTest < Minitest::Test
  def test_highlights_full_field_with_searchkick_tags
    assert_equal "Two Door <em>Cinema</em> Club", highlight("Two Door Cinema Club", '"cinema"')
    text = ("Cinema Club " * 100).strip
    assert_equal ("<em>Cinema</em> Club " * 100).strip, highlight(text, '"cinema"')
  end

  def test_custom_tag_and_attributes
    assert_equal "<strong class='match'>Cinema</strong>", highlight("Cinema", '"cinema"', tag: "<strong class='match'>")
  end

  def test_tag_content_is_literal_and_does_not_expand_tin_placeholders
    assert_equal '<mark title="$QUERY_PART">Cinema</mark>', highlight("Cinema", '"cinema"', tag: '<mark title="$QUERY_PART">')
  end

  def test_default_encoder_preserves_source_html_as_an_ordinary_string
    result = highlight("<b>Hello</b>", '"hello"')
    assert_equal "<b><em>Hello</em></b>", result
    assert_instance_of String, result
  end

  def test_html_encoder_escapes_source_but_preserves_highlight_tags
    text = %q(<b title="rock & roll's">Hello / café 😀</b>)
    assert_equal "&lt;b title=&quot;rock &amp; roll&#x27;s&quot;&gt;<em>Hello</em> &#x2F; café 😀&lt;&#x2F;b&gt;",
      highlight(text, '"hello"', encoder: "html")
  end

  def test_returns_nil_without_matching_spans
    assert_nil highlight("Cinema", '"pear"')
    assert_nil highlight("Cinema", "*")
    assert_nil highlight("Cinema", "")
    assert_nil highlight(nil, '"cinema"')
  end

  def test_phrase_and_unicode_spans_use_native_matching
    assert_equal "A <em>crisp apple</em> pie", highlight("A crisp apple pie", '"crisp apple"')
    assert_equal "<em>Jalapeño</em> 😀", highlight("Jalapeño 😀", '"jalapeno"')
  end

  def test_source_marker_text_is_not_treated_as_an_inserted_tag
    text = "\u0001tinkickstart\u0002 Hello \u0001tinkickend\u0002"
    assert_equal "\u0001tinkickstart\u0002 <em>Hello</em> \u0001tinkickend\u0002", highlight(text, '"hello"')
  end

  def test_unknown_encoder_fails_clearly
    error = assert_raises(ArgumentError) { highlight("Hello", '"hello"', encoder: "unknown") }
    assert_match "encoder must be default or html", error.message
  end

  private

  def highlight(text, query, **options)
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::Highlighter.new(connection).highlight(text, query, **options)
    end
  end
end
