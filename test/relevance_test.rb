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

  def test_explicit_descending_score_order_keeps_countless_top_k
    output = StringIO.new
    previous_logger = SearchDocument.logger
    SearchDocument.logger = Logger.new(output)
    statements = []
    callback = ->(*arguments) { statements << arguments.last if arguments.last[:name] == "SearchDocument Load" }
    page = search("mithril lantern", order: { _score: :desc }, limit: 2, countless: true)
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal [:frequency_high, :length_short].map { |key| document(key).id }.sort, page.map(&:id).sort
      assert page.has_next_page?
    end
    statement = statements.find { |value| value[:sql].include?("_tinkick_score") }
    refute_nil statement
    plan = SearchDocument.connection.select_value(
      "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}", "Tinkick Score Order Explain", statement.fetch(:binds)
    )
    assert_includes plan, '"Top K": "3"'
    refute_match(/"Node Type": "Sort"/, plan)
    refute_includes output.string, "column order"
  ensure
    SearchDocument.logger = previous_logger
  end

  def test_array_score_sort_defaults_to_descending_but_scalar_sort_to_ascending
    descending = search("mithril lantern", order: [:_score]).with_score.to_a
    ascending = search("mithril lantern", order: :_score).with_score.to_a
    assert_equal 4, descending.length
    assert_equal descending.map { |record, _score| record.id }.sort, ascending.map { |record, _score| record.id }.sort
    assert_equal descending.map(&:last).sort.reverse, descending.map(&:last)
    assert_equal ascending.map(&:last).sort, ascending.map(&:last)
    assert_equal document(:length_long).id, ascending.first.first.id
  end

  def test_score_can_be_combined_with_column_tiebreakers
    original = document(:frequency_high)
    SearchDocument.create!(title: original.title, body: original.body, category: original.category)
    pairs = search("mithril lantern", order: [{ _score: :desc }, { id: :desc }]).with_score.to_a
    expected = pairs.sort_by { |record, score| [-score, -record.id] }
    assert_equal 5, pairs.length
    assert_equal expected.map { |record, _score| record.id }, pairs.map { |record, _score| record.id }
  end

  def test_score_order_does_not_make_score_cursors_stable
    error = assert_raises(Tinkick::InvalidQueryError) do
      search("mithril lantern", order: { _score: :desc }, keyset: true, limit: 2).to_a
    end
    assert_match(/column/, error.message)
  end

  def test_ascending_and_compound_relevance_order_warn_about_sort_cost
    output = StringIO.new
    previous_logger = SearchDocument.logger
    SearchDocument.logger = Logger.new(output)
    search("mithril lantern", order: { _score: :asc }).to_a
    assert_includes output.string, "sort matching rows"
    output.truncate(0)
    output.rewind
    search("mithril lantern", order: [{ _score: :desc }, :id]).to_a
    assert_includes output.string, "sort matching rows"
  ensure
    SearchDocument.logger = previous_logger
  end

  private

  def document(key)
    tinkick_test_documents(key)
  end

  def search(term, **options)
    SearchDocument.tinkick_search(term, misspellings: false, **options)
  end
end
