# frozen_string_literal: true

require_relative "../integration_helper"
require_relative "../../lib/tinkick/word_match"
require_relative "../../lib/tinkick/highlighter"

class WordMatchHighlightTest < TinkickIntegrationTest
  def test_refined_highlighting_excludes_broad_candidate_only_tokens
    texts = ["abcdefghij zzdcfeghxj abdcfeghij", "Distant hillside"]
    query = highlight_query("abdcfeghij", texts)

    assert_equal(["<em>abcdefghij</em> zzdcfeghxj <em>abdcfeghij</em>", nil], highlight(texts, query))
    refute_includes(query, "zzdcfeghxj")
  end

  def test_prefixes_and_restricted_transposition_rules_match_search_eligibility
    texts = ["apple papel"]
    assert_equal(["<em>apple</em> <em>papel</em>"], highlight(texts, highlight_query("papel", texts)))
    assert_equal(["apple <em>papel</em>"], highlight(texts, highlight_query("papel", texts, prefix_length: 1)))
    assert_equal(["apple <em>papel</em>"], highlight(texts, highlight_query("papel", texts, transpositions: false)))

    texts = ["abc ca"]
    assert_equal(["abc <em>ca</em>"], highlight(texts, highlight_query("ca", texts)))
  end

  def test_partial_matches_highlight_the_complete_eligible_token
    { word_start: "appletree", word_middle: "pineappletree", word_end: "pineapple" }.each do |mode, text|
      texts = ["#{text} zzzzzzzz"]
      query = highlight_query("papel", texts, match: mode)

      assert_equal(["<em>#{text}</em> zzzzzzzz"], highlight(texts, query), mode.to_s)
    end
  end

  def test_partial_gram_lengths_remain_bounded_at_fifty_characters
    texts = ["a" * 50 + "suffix"]
    query = highlight_query("a" * 52, texts, match: :word_start, transpositions: false)
    assert_equal(["<em>#{texts.first}</em>"], highlight(texts, query))
    assert_equal("", highlight_query("a" * 53, texts, match: :word_start, transpositions: false))
    assert_equal("", highlight_query("a" * 52, texts, match: :word_start, prefix_length: 51))
  end

  def test_unicode_and_keycap_literals_keep_original_highlight_spans
    texts = ["Jalapeño *️⃣ #️⃣"]
    query = highlight_query("ajlapneo #️⃣", texts)

    assert_equal(["<em>Jalapeño</em> <em>*️⃣</em> <em>#️⃣</em>"], highlight(texts, query))
  end

  def test_empty_inputs_and_nonmatching_tokens_do_not_create_a_query
    assert_equal("", highlight_query("apple", []))
    assert_equal("", highlight_query("apple", [nil, nil]))
    assert_equal("", highlight_query("", ["Apple"]))
    assert_equal("", highlight_query("apple", ["Distant hillside"]))
    assert_equal("", highlight_query('"; DROP TABLE tinkick_test_products; --', ["Apple"]))
  end

  def test_page_texts_use_one_token_eligibility_batch_and_never_load_model_rows
    texts = ["Apple", nil, "Pear", "Apple Apple"]
    # Warm metadata so this records only helper prerequisites and eligibility.
    highlight_query("apple", ["Apple"])
    statements = []
    callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }

    query = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      query = highlight_query("apple", texts)
    end
    batches = statements.select { |entry| entry.fetch(:sql).include?("jsonb_array_elements_text") }
    assert_equal(1, batches.length)
    refute(statements.any? { |entry| entry.fetch(:sql).include?('FROM "tinkick_test_products"') })
    assert_equal(["<em>Apple</em>", nil, nil, "<em>Apple</em> <em>Apple</em>"], highlight(texts, query))

    batch = batches.fetch(0)
    plan = SearchProduct.connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{batch.fetch(:sql)}",
      "Tinkick Refined Highlight Explain", batch.fetch(:binds))
    assert_includes(plan, "jsonb_array_elements_text")
    refute_includes(plan, "tinkick_test_products")
  end

  private

  def highlight_query(term, texts, match: :word, **options)
    Tinkick::WordMatch.new(SearchProduct).highlight_query("name", term, texts: texts, match: match,
      misspellings: { edit_distance: 2, **options })
  end

  def highlight(texts, query)
    Tinkick::Highlighter.new(SearchProduct.connection).highlight_many(texts, query)
  end
end
