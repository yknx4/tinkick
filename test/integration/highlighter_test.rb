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

  def test_batch_highlighting_preserves_positions_with_one_bound_database_query
    statements = []
    listener = ->(*arguments) { statements << arguments.last if arguments.last[:name] == "Tinkick Highlight" }
    texts = ["Mithril lantern in Moria", nil, "Unrelated orchard harvest", "<b>Mithril lantern</b> 😀", "Mithril bright lantern"]
    expected = ["<mark>Mithril lantern</mark> in Moria", nil, nil, "&lt;b&gt;<mark>Mithril lantern</mark>&lt;&#x2F;b&gt; 😀", nil]
    ActiveRecord::Base.with_connection do |connection|
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        actual = Tinkick::Highlighter.new(connection).highlight_many(texts, '"mithril lantern"', tag: "<mark>", encoder: "html")
        assert_equal expected, actual
      end
    end
    assert_equal 1, statements.length
    refute_includes statements.first.fetch(:sql), "Mithril"
  end

  def test_batch_markers_are_literal_and_nonmatching_inputs_skip_sql
    text = "\u0001tinkickstart\u0002 Hello"
    expected = "\u0001tinkickstart\u0002 <mark title='$QUERY_PART'>Hello</mark>"
    ActiveRecord::Base.with_connection do |connection|
      highlighter = Tinkick::Highlighter.new(connection)
      assert_equal [expected, "<mark title='$QUERY_PART'>Hello</mark>"],
        highlighter.highlight_many([text, "Hello"], '"hello"', tag: "<mark title='$QUERY_PART'>")
      statements = []
      listener = ->(*arguments) { statements << arguments.last[:sql] }
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        assert_empty highlighter.highlight_many([], '"hello"')
        assert_equal [nil, nil], highlighter.highlight_many(["Hello", nil], "*")
        assert_equal [nil], highlighter.highlight_many(["Hello"], "")
        assert_equal [nil, nil], highlighter.highlight_many([nil, nil], '"hello"')
      end
      assert_empty statements
    end
  end

  def test_fragments_default_to_full_fields_and_preserve_batch_positions
    text = ("Cinema Club " * 100).strip
    expected = ("<em>Cinema</em> Club " * 100).strip
    assert_equal [[expected], [], []], fragments([text, "Other music", nil], '"cinema"')
    assert_equal [[], []], fragments(["Cinema", nil], "*")
  end

  def test_positive_fragment_size_returns_separate_complete_highlights
    text = "Two Door Cinema Club Some Other Words And Much More Doors Cinema Club"
    result = fragments([text], '"cinema"', fragment_size: 20).first
    assert_equal 2, result.length
    assert_equal result.uniq, result
    result.each do |fragment|
      assert_includes fragment, "<em>Cinema</em>"
      assert_operator fragment.length, :<, text.length
    end
    assert_includes result.first, "Door"
    assert_includes result.last, "Doors"
  end

  def test_fragment_limit_defaults_to_five_and_can_be_overridden
    text = (1..8).map { |number| "Section#{number} Cinema ending#{number} #{'distant filler ' * 8}" }.join
    defaults = fragments([text], '"cinema"', fragment_size: 24).first
    assert_equal 5, defaults.length
    defaults.each_with_index do |fragment, index|
      assert_includes fragment, "Section#{index + 1}"
      assert_includes fragment, "<em>Cinema</em>"
    end
    assert_equal defaults.first(2), fragments([text], '"cinema"', fragment_size: 24, number_of_fragments: 2).first
    assert_equal [text.gsub("Cinema", "<em>Cinema</em>")],
      fragments([text], '"cinema"', fragment_size: 24, number_of_fragments: 0).first
  end

  def test_snippets_do_not_repeat_identical_context_or_split_long_matching_phrases
    repeated = "before Cinema after #{'distant filler ' * 8}before Cinema after"
    assert_equal ["before <em>Cinema</em> after"], fragments([repeated], '"cinema"', fragment_size: 19).first
    text = "far away a wonderfully crisp apple pie beyond the orchard"
    result = fragments([text], '"wonderfully crisp apple"', fragment_size: 4).first
    assert_equal ["<em>wonderfully crisp apple</em>"], result
  end

  def test_snippets_keep_unicode_graphemes_and_escape_html_after_slicing
    text = "far away 👩🏽‍🚀 <b>Jalapeño</b> & e\u0301lan elsewhere #{'more words ' * 8}"
    result = fragments([text], '"jalapeno"', fragment_size: 24, encoder: "html", tag: '<mark title="$QUERY_PART">').first
    assert_equal 1, result.length
    fragment = result.first
    assert fragment.valid_encoding?
    assert_includes fragment, "👩🏽‍🚀"
    assert_includes fragment, '&lt;b&gt;<mark title="$QUERY_PART">Jalapeño</mark>&lt;&#x2F;b&gt;'
    assert_includes fragment, "&amp;"
    assert_includes fragment, "e\u0301lan"
    refute_includes fragment, "tinkick"
    refute_includes fragment, "<b>"
  end

  def test_fragments_share_one_bound_query_and_skip_nonmatching_controls
    statements = []
    listener = ->(*arguments) { statements << arguments.last if arguments.last[:name] == "Tinkick Highlight" }
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      result = fragments(["Cinema in Moria", "Cinema in Gondor", nil], '"cinema"', fragment_size: 10)
      assert_equal 3, result.length
      assert_empty result.last
      assert_equal [], fragments([], '"cinema"', fragment_size: 10)
      assert_equal [[], []], fragments(["Cinema", nil], "*", fragment_size: 10)
    end
    assert_equal 1, statements.length
    refute_includes statements.first.fetch(:sql), "Cinema"
  end

  def test_fragment_options_reject_negative_or_noninteger_values
    [:fragment_size, :number_of_fragments].each do |option|
      [-1, 1.5, "2"].each do |value|
        error = assert_raises(ArgumentError) { fragments(["Cinema"], '"cinema"', **{ option => value }) }
        assert_includes error.message, "#{option} must be a nonnegative integer"
      end
    end
  end

  private

  def highlight(text, query, **options)
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::Highlighter.new(connection).highlight(text, query, **options)
    end
  end

  def fragments(texts, query, **options)
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::Highlighter.new(connection).fragments_many(texts, query, **options)
    end
  end
end
