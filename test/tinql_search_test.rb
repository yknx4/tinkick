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

  def test_proximity_distinguishes_order_and_extra_word_gaps
    ordered = document(:phrase_ordered).id
    reversed = document(:phrase_reversed).id
    gap = document(:phrase_gap).id
    assert_equal [ordered, reversed].sort, search({ near: ["Gondolin", "sentries"], distance: 0 }).map(&:id).sort
    assert_equal [ordered], search({ then: ["Gondolin", "sentries"], distance: 0 }).map(&:id)
    assert_equal [ordered, gap].sort, search({ then: ["Gondolin", "sentries"], distance: 1 }).map(&:id).sort
    assert_equal [ordered, reversed, gap].sort, search({ near: ["Gondolin", "sentries"], distance: 1 }).map(&:id).sort
    assert_empty search({ within: { near: ["Gondolin", "sentries"], distance: 1 }, words: 1 })
  end

  def test_phrase_gaps_alternatives_and_tolerance
    assert_equal [document(:phrase_gap).id], search({ phrase: ["Gondolin", nil, "sentries"] }).map(&:id)
    assert_equal [document(:phrase_gap).id], search({ phrase: ["Gondolin", ["young", "veteran"], "sentries"] }).map(&:id)
    expected = [:phrase_ordered, :phrase_gap].map { |key| document(key).id }.sort
    assert_equal expected, search({ phrase: "Gondolin sentries", slop: 1 }).map(&:id).sort
    assert_equal [document(:phrase_ordered).id], search({ phrase: "Gondolin sentries", slop: 0 }).map(&:id)
    # Literal punctuation cannot introduce phrase gaps or alternatives.
    assert_empty search({ phrase: ["Gondolin", "[young veteran]", "sentries"] })
  end

  def test_proximity_configuration_rejects_misspelled_options_and_invalid_bounds
    [{ near: ["a", "b"] }, { then: ["a", "b"], distance: -1 },
      { near: ["a"], distance: 2 }, { near: ["a", "b"], distance: 1.5 },
      { within: "a", words: 0 }, { phrase: "a", slop: -1 },
      { phrase: ["a", []] }, { near: ["a", "b"], distance: 2, typo: 1 }].each do |expression|
      assert_raises(ArgumentError, expression.inspect) { search(expression).to_a }
    end
  end

  def test_minimum_match_groups_and_nested_alternatives
    terms = ["Gondolin", "sentries", "astrolabe"]
    assert_equal 4, search({ at_least: terms, count: 2 }).total_count
    assert_equal 4, search({ at_least: terms, percent: 50 }).total_count
    assert_empty search({ at_least: terms, percent: 100 })
    assert_equal 3, search({ all_of: ["Gondolin", "sentries"] }).total_count
    assert_equal 2, search({ any_of: [{ phrase: "Gondolin sentries" }, "astrolabe"] }).total_count
  end

  def test_native_token_wildcards_regex_ranges_and_fuzzy_distance
    expected = [document(:typo_exact).id]
    assert_equal expected, search({ wildcard: "astro?abe" }).map(&:id)
    assert_equal expected, search({ wildcard: "*rolabe" }).map(&:id)
    assert_equal expected, search({ matches: "astro(labe|nomy)" }).map(&:id)
    assert_equal expected, search({ range: ["astrolabe", "astrolabe"] }).map(&:id)
    assert_equal expected, search({ fuzzy: "astrolbe", distance: 1, prefix: 3 }).map(&:id)
    assert_empty search({ fuzzy: "astrolbe", distance: 0 })
    assert_equal SearchDocument.count, search({ all: true }).total_count
    assert_equal expected, search({ term: "astrolabe" }).map(&:id)
    [[nil, "astrolabe"], ["sentries", nil]].each do |bounds|
      native = "#{bounds[0] || '*'} TO #{bounds[1] || '*'}"
      assert_equal SearchDocument.where("body ==> ?", native).order(:id).ids,
        search({ range: bounds }).order(:id).map(&:id)
    end
  end

  def test_expression_boosts_keep_native_scores_and_top_results
    expression = { boost: { and: ["mithril", "lantern"] }, factor: 3 }
    boosted = search(expression).with_score.to_h { |record, score| [record.id, score] }
    plain = search(and: ["mithril", "lantern"]).with_score.to_h { |record, score| [record.id, score] }
    assert_equal plain.keys.sort, boosted.keys.sort
    plain.each { |id, score| assert_in_delta score * 3, boosted.fetch(id), 0.00001 }
    assert_equal [:frequency_high, :length_short].map { |key| document(key).id }.sort,
      search(expression).limit(2).map(&:id).sort
  end

  def test_token_patterns_and_groups_reject_ambiguous_input
    [{ wildcard: "foo OR *" }, { matches: "foo OR *" }, { fuzzy: "two words", distance: 1 },
      { fuzzy: "word", distance: -1 }, { range: ["a"] }, { all: false },
      { at_least: ["a"], count: 1, percent: 50 }, { at_least: ["a"], percent: 101 },
      { boost: "word", factor: Float::INFINITY }, { boost: "word", factor: 10_001 }].each do |expression|
      assert_raises(ArgumentError, expression.inspect) { search(expression).to_a }
    end
  end

  def test_span_relations_select_the_expected_documents
    records = positional_documents
    outer = { near: ["quartz", "harbor"], distance: 2 }
    crossing = { near: ["cedar", "amber"], distance: 2 }
    cases = {
      encloses: [[outer, "cedar"], [0, 2]],
      not_encloses: [[outer, "cedar"], [1, 3]],
      enclosed_by: [["cedar", outer], [0, 2]],
      not_enclosed_by: [["cedar", outer], [1, 3]],
      overlapping: [[outer, crossing], [0, 1, 2]],
      not_overlapping: [[outer, crossing], [3]],
      before: [["quartz", "cedar"], [0, 3]],
      after: [["quartz", "cedar"], [1, 2]],
    }
    cases.each do |operator, (operands, positions)|
      assert_equal positions.map { |i| records.fetch(i).id }.sort,
        search({ operator => operands }).map(&:id).sort, operator.to_s
    end
  end

  def test_word_and_percentage_positions
    records = positional_documents
    cases = [
      [{ in_first: "quartz", words: 1 }, [0, 3]],
      [{ in_last: "quartz", words: 1 }, [2]],
      [{ in_first: "quartz", percent: 50 }, [0, 1, 3]],
      [{ in_last: "quartz", percent: 50 }, [2]],
      [{ in_middle: "quartz", percent: 50 }, [1]],
      [{ in_words: "quartz", from: 0, to: 0 }, []],
      [{ in_words: "quartz", from: 1, to: 1 }, [0, 3]],
      [{ in_words: "quartz", from: 2, to: 2 }, [1]],
    ]
    cases.each do |expression, positions|
      assert_equal positions.map { |i| records.fetch(i).id }.sort,
        search(expression).map(&:id).sort, expression.inspect
    end
    # Verified on TIN 1.0.2 and pinned Lead: IN WORDS is one-based, despite
    # the public documentation describing zero-based positions. Pass it through.
    native = SearchDocument.where("body ==> ?", "quartz IN WORDS 2 TO 2").ids
    assert_equal native, search({ in_words: "quartz", from: 2, to: 2 }).map(&:id)
  end

  def test_span_and_position_validation
    [{ before: ["a"] }, { in_first: "a", words: 1, percent: 50 },
      { in_last: "a" }, { in_middle: "a", words: 2 },
      { in_middle: "a", percent: 101 }, { in_words: "a", from: 3, to: 1 }].each do |expression|
      assert_raises(ArgumentError, expression.inspect) { search(expression).to_a }
    end
  end

  private

  def positional_documents
    ["quartz cedar harbor amber", "cedar quartz amber harbor",
      "amber harbor cedar quartz", "quartz harbor amber cedar"].map do |body|
      SearchDocument.create!(title: "Navigation signals", body: body, category: "navigation")
    end
  end

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
