# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class TinqlSearchTest < ActiveSupport::TestCase
  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  def test_native_expression_filters_and_ranks_the_varied_corpus
    result = search(and: ["mithril", "lantern"])
    expected = SearchDocument.tinkick_search("mithril lantern", misspellings: false)
    assert_equal expected.with_score.map { |record, score| [record.id, score] }, result.with_score.map { |record, score| [record.id, score] }
    assert_equal 4, result.total_count
    refute_includes result.map(&:id), document(:unrelated_curated).id
  end

  def test_boolean_expressions_and_raw_native_queries
    assert_equal [document(:phrase_ordered).id], search(raw: '"Gondolin sentries"').map(&:id)
    assert_equal 4, search(or: ["Gondolin", "neverfoundtoken"]).total_count
    assert_equal 1, search(and_not: ["Gondolin", "sentries"]).total_count
    assert_empty search("Gondolin OR *")
    assert_empty search(raw: '"Gondolin" AND "neverfoundtoken"')
  end

  def test_tinql_combines_with_literal_search_and_sql_scopes
    expression = { raw: '"Gondolin sentries"' }
    assert_equal [document(:phrase_ordered).id], SearchDocument.tinkick_search("Gondolin", tinql: expression).map(&:id)
    assert_empty SearchDocument.tinkick_search("astrolabe", tinql: expression)
    assert_empty SearchDocument.where(category: "food").tinkick_search(tinql: expression)
  end

  def test_relation_chaining_is_independent_and_available_on_global_search
    original = SearchDocument.tinkick_search("Gondolin", misspellings: false)
    narrowed = original.tinql(raw: '"Gondolin sentries"')
    assert_equal 4, original.total_count
    assert_equal 1, narrowed.total_count
    assert_equal 4, narrowed.except(:tinql).total_count
    assert_equal narrowed.map(&:id), Tinkick.search(model: SearchDocument, tinql: { raw: '"Gondolin sentries"' }).map(&:id)
  end

  def test_counts_aggregations_highlights_and_query_hook_share_the_expression
    result = SearchDocument.tinkick_search(tinql: { raw: '"Gondolin sentries"' }, aggs: [:category], highlight: true) do |query|
      query.where(id: document(:phrase_ordered).id)
    end
    assert_equal 1, result.total_count
    assert_equal 1, result.aggs.fetch("category").fetch("buckets").sum { |bucket| bucket.fetch("doc_count") }
    assert_includes result.highlights.first.fetch(:body), "<em>"
    assert_equal 2, search(and: ["Gondolin", "sentries"], exclude: "Gondolin sentries").total_count
  end

  def test_native_patterns_are_bound_as_data_and_invalid_shapes_fail_clearly
    assert_empty search(raw: %q("x'; SELECT pg_sleep(10); --"))
    [{ and: [] }, { wat: "Gondolin" }, { and: "Gondolin" }, { raw: 1 }, { raw: "*", or: ["Gondolin"] }].each do |expression|
      assert_raises(ArgumentError) { search(expression).to_a }
    end
    assert_raises(ArgumentError) { search({ raw: "*" }, match: :exact).to_a }
  end

  private

  def search(expression = nil, **options)
    # Allow concise expression hashes while keeping search options explicit.
    expression ||= options.slice(:and, :or, :and_not, :raw)
    options = options.except(:and, :or, :and_not, :raw)
    SearchDocument.tinkick_search(tinql: expression, **options)
  end

  def document(key)
    tinkick_test_documents(key)
  end
end
