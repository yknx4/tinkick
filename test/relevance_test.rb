# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class RelevanceTest < ActionDispatch::IntegrationTest
  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  def test_corpus_contains_multiple_topics_and_varied_document_lengths
    assert_equal 268, SearchDocument.count
    assert_equal 64, SearchDocument.where(category: "travel").count
    assert_equal 64, SearchDocument.where(category: "food").count
    assert_equal 64, SearchDocument.where(category: "technical").count
    assert_equal 64, SearchDocument.where(category: "fantasy").count
    assert_operator document(:length_long).body.length, :>, document(:length_short).body.length * 20
    # Keep both ranking terms below TIN's default 10% dense-term cutoff.
    %w[mithril lantern].each do |term|
      assert_operator search(term).total_count, :<, SearchDocument.count * 0.1
    end
  end

  def test_higher_term_frequency_ranks_above_lower_frequency_at_equal_length
    high = document(:frequency_high)
    low = document(:frequency_low)
    assert_equal high.body.split.length, low.body.split.length

    pairs = search("mithril lantern").with_score.to_a
    ranks = pairs.map { |record, _score| record.id }
    scores = pairs.to_h { |record, score| [record.id, score] }

    # Both documents have the same length; repeating the two rare search terms
    # should beat replacing three occurrences with other words.
    assert_operator ranks.index(high.id), :<, ranks.index(low.id)
    assert_operator scores.fetch(high.id), :>, scores.fetch(low.id)
  end

  def test_shorter_document_ranks_above_longer_document_with_equal_occurrences
    short = document(:length_short)
    long = document(:length_long)
    pairs = search("mithril lantern").with_score.to_a
    ranks = pairs.map { |record, _score| record.id }
    scores = pairs.to_h { |record, score| [record.id, score] }

    # The long document appends unrelated prose to the same matching sentence.
    # Length normalization should favor the concise result at equal frequency.
    assert_operator ranks.index(short.id), :<, ranks.index(long.id)
    assert_operator scores.fetch(short.id), :>, scores.fetch(long.id)
  end

  def test_top_k_keeps_the_strong_matches_among_unrelated_documents
    expected = [:frequency_high, :length_short].map { |key| document(key).id }.sort

    assert_equal expected, search("mithril lantern", limit: 2).map(&:id).sort
    assert_equal 4, search("mithril lantern").total_count
    refute_includes search("mithril lantern").map(&:id), document(:unrelated_curated).id
  end

  def test_all_terms_must_match_the_same_search_field
    results = search("Moria Balrog", fields: [:title, :body]).map(&:id)

    assert_includes results, document(:and_same_field).id
    refute_includes results, document(:and_split_fields).id
    refute_includes results, document(:and_partial).id
    assert_equal [document(:and_same_field).id], results
  end

  def test_phrase_preserves_order_and_adjacency
    expected = [:phrase_ordered, :phrase_reversed, :phrase_gap].map { |key| document(key).id }.sort

    assert_equal expected, search("Gondolin sentries").map(&:id).sort
    assert_equal [document(:phrase_ordered).id], search("Gondolin sentries", match: :phrase).map(&:id)
  end

  def test_typo_recovery_finds_the_intended_document_in_the_full_corpus
    expected = [document(:typo_exact).id]

    assert_equal expected, search("astrolabe").map(&:id)
    assert_equal expected, SearchDocument.tinkick_search("astrolbae").map(&:id)
    assert_empty search("astrolbae")
  end

  private

  def document(key)
    tinkick_test_documents(key)
  end

  def search(term, **options)
    SearchDocument.tinkick_search(term, misspellings: false, **options)
  end
end
