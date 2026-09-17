# frozen_string_literal: true

require_relative "../integration_helper"
require "tinkick/highlighter"

class HighlighterSpansTest < Minitest::Test
  def test_character_offsets_preserve_unicode_and_encode_source_separately_from_tags
    source = "😀 <b>Éowyn</b> & cafe\u0301"
    spans = ["Éowyn", "cafe\u0301"].map { |word| [source.index(word), source.index(word) + word.length] }
    result = render([source], [spans], encoder: "html", tag: '<mark title="$QUERY_PART">')

    assert_equal [['😀 &lt;b&gt;<mark title="$QUERY_PART">Éowyn</mark>&lt;&#x2F;b&gt; &amp; ' \
      "<mark title=\"$QUERY_PART\">cafe\u0301</mark>"]], result
  end

  def test_supplied_spans_share_native_snippet_and_fragment_limit_behavior
    source = "Gondor lantern before #{'distant filler ' * 8}Rohan lantern after"
    spans = source.to_enum(:scan, /lantern/).map { [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
    ActiveRecord::Base.with_connection do |connection|
      highlighter = Tinkick::Highlighter.new(connection)
      [{}, { fragment_size: 20 }, { fragment_size: 20, number_of_fragments: 1 },
        { fragment_size: 20, number_of_fragments: 0 }].each do |settings|
        expected = highlighter.fragments_many([source], '"lantern"', **settings)
        assert_equal expected, highlighter.fragments_from_spans([source], [spans], **settings)
      end
    end
  end

  def test_original_marker_text_is_preserved
    source = "\u0001tinkickstart\u0002 Éowyn \u0001tinkickend\u0002"
    first = source.index("Éowyn")

    assert_equal [["\u0001tinkickstart\u0002 <em>Éowyn</em> \u0001tinkickend\u0002"]],
      render([source], [[[first, first + 5]]])
  end

  def test_rendering_preserves_page_positions_without_database_work
    ActiveRecord::Base.with_connection do |connection|
      highlighter = Tinkick::Highlighter.new(connection)
      statements = []
      listener = ->(*arguments) { statements << arguments.last[:sql] }
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        assert_equal [[], ["<em>Éowyn</em>"], [], []],
          highlighter.fragments_from_spans([nil, "Éowyn", "Other", ""], [[], [[0, 5]], [], []])
        assert_equal [], highlighter.fragments_from_spans([], [])
        assert_raises(ArgumentError) { highlighter.fragments_from_spans(["Éowyn"], [[[0, 5]]], encoder: "unknown") }
      end
      assert_empty statements
    end
  end

  private

  def render(texts, spans, **options)
    ActiveRecord::Base.with_connection do |connection|
      Tinkick::Highlighter.new(connection).fragments_from_spans(texts, spans, **options)
    end
  end
end
