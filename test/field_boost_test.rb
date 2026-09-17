# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "test_helper"
require_relative "dummy/config/environment"
require_relative "integration_helper"
require "rails/test_help"

class FieldBoostTest < ActionDispatch::IntegrationTest
  class DefaultDocument < ActiveRecord::Base
    self.table_name = "tinkick_test_documents"
    tinkick searchable: [:title, :body], default_fields: ["title^100", :body]
  end

  self.fixture_paths = [File.expand_path("dummy/test/fixtures", __dir__)]
  self.use_transactional_tests = true
  set_fixture_class(tinkick_test_documents: SearchDocument)
  fixtures :tinkick_test_documents

  def test_field_weights_reverse_ranking_in_a_varied_corpus
    title_hit, body_hit = boost_documents

    assert_equal [title_hit.id, body_hit.id], search("sunforge", fields: ["title^100", :body]).map(&:id)
    assert_equal [body_hit.id, title_hit.id], search("sunforge", fields: [:title, "body^100"]).map(&:id)
    assert_equal 270, SearchDocument.count
  end

  def test_decimal_boost_scales_all_terms_of_a_single_field_query
    baseline = scores(search("mithril lantern", fields: ["body^1"]))
    quarter = scores(search("mithril lantern", fields: ["body^0.25"]))

    assert_equal 4, baseline.length
    assert_equal baseline.keys.sort, quarter.keys.sort
    baseline.each do |id, score|
      assert_operator score, :>, 0
      assert_score score * 0.25, quarter.fetch(id)
    end
  end

  def test_zero_boost_keeps_matches_and_suppresses_only_the_selected_field_score
    title_hit, body_hit = boost_documents
    page = search("sunforge", fields: ["title^0", "body^1"])
    weighted = scores(page)

    assert_equal 2, page.total_count
    assert_equal [body_hit.id, title_hit.id], page.map(&:id)
    assert_equal 0.0, weighted.fetch(title_hit.id)
    assert_operator weighted.fetch(body_hit.id), :>, 0
  end

  def test_zero_boost_on_the_only_field_does_not_turn_a_search_into_no_matches
    page = search("mithril lantern", fields: ["body^0"])

    assert_equal 4, page.total_count
    assert_equal [0.0], page.with_score.map { |_record, score| score }.uniq
    assert_equal search("mithril lantern").map(&:id).sort, page.map(&:id).sort
  end

  def test_native_upper_bound_is_accepted
    baseline = scores(search("mithril lantern", fields: ["body^1"]))
    boosted = scores(search("mithril lantern", fields: ["body^10000"]))

    baseline.each { |id, score| assert_score score * 10_000, boosted.fetch(id) }
  end

  def test_last_explicit_duplicate_boost_wins_and_an_unboosted_duplicate_does_not_reset_it
    # Searchkick resolves boosts by original selector and match mode before
    # building clauses; all three occurrences therefore receive the last 3.
    explicit = scores(search("mithril lantern", fields: ["body^3", "body^3", "body^3"]))
    ["body^2", "body^1e309"].each do |first|
      mixed = scores(search("mithril lantern", fields: [first, "body^3", :body]))
      assert_scores_equal explicit, mixed
    end
  end

  def test_duplicate_field_names_keep_independent_boosts_for_different_match_modes
    phrase = scores(search("mithril lantern", fields: [{ "body^3" => :phrase }]))
    mixed = scores(search("mithril lantern", fields: [{ "body^3" => :phrase }, { "body^0" => :word }]))

    assert_scores_equal phrase, mixed
  end

  def test_model_default_fields_apply_boosts_without_treating_them_as_schema_columns
    title_hit, body_hit = boost_documents

    assert_equal [title_hit.id, body_hit.id], DefaultDocument.search("sunforge", misspellings: false).map(&:id)
    assert_equal [body_hit.id, title_hit.id], DefaultDocument.search("sunforge", fields: [:title, "body^100"],
      misspellings: false).map(&:id)
  end

  def test_fluent_fields_apply_boosts_without_mutating_the_original_relation
    title_hit, body_hit = boost_documents
    original = SearchDocument.search("sunforge", fields: [:title], misspellings: false)
    boosted = original.fields(:title, "body^100")

    assert_equal [body_hit.id, title_hit.id], boosted.map(&:id)
    assert_equal [title_hit.id], original.map(&:id)
    refute_same original, boosted
  end

  def test_boosted_star_expands_searchable_fields_independently_of_default_fields
    title_hit, body_hit = boost_documents
    wildcard = search("sunforge", fields: ["*^3"])
    concrete = search("sunforge", fields: ["title^3", "body^3"])

    assert_equal [title_hit.id, body_hit.id].sort, wildcard.map(&:id).sort
    assert_scores_equal scores(concrete), scores(wildcard)
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "tinkick_test_documents"
      tinkick searchable: [:title, :body], default_fields: ["*^3"]
    end
    assert_scores_equal scores(concrete), scores(model.search("sunforge", misspellings: false))
  end

  def test_wildcard_boost_does_not_leak_into_an_independently_requested_concrete_field
    title_hit, body_hit = boost_documents
    baseline = scores(search("sunforge", fields: ["*^1"]))
    boosted = scores(search("sunforge", fields: ["*^4", :title]))

    # The wildcard's title branch has factor 4, while the separate concrete
    # title clause keeps its own implicit factor 1. The body has only factor 4.
    assert_score baseline.fetch(title_hit.id) * 5, boosted.fetch(title_hit.id)
    assert_score baseline.fetch(body_hit.id) * 4, boosted.fetch(body_hit.id)
  end

  def test_per_field_misspellings_use_the_name_without_its_boost_suffix
    expected = [document(:typo_exact).id]

    assert_equal expected, search("astrolbe", fields: ["body^2"], misspellings: { fields: ["body"] }).map(&:id)
    assert_empty search("astrolbe", fields: ["body^2"], misspellings: { fields: [] })
    error = assert_raises(ArgumentError) do
      search("astrolbae", fields: ["body^2"], misspellings: { fields: ["body^2"] })
    end
    assert_includes error.message, "must also be specified in fields option"
  end

  def test_per_field_misspellings_use_the_original_wildcard_without_its_boost_suffix
    assert_equal [document(:typo_exact).id], search("astrolbe", fields: ["*^2"],
      misspellings: { fields: ["*"] }).map(&:id)
    error = assert_raises(ArgumentError) do
      search("astrolbae", fields: ["*^2"], misspellings: { fields: ["*^2"] })
    end
    assert_includes error.message, "must also be specified in fields option"
  end

  def test_native_partial_field_modes_preserve_boosts
    title_hit, body_hit = boost_documents
    fields = [{ "title^100" => :word_start }, { body: :word_start }]

    assert_equal [title_hit.id, body_hit.id], search("sunf", fields: fields).map(&:id)
    assert_empty search("forge", fields: fields)
  end

  def test_native_two_edit_matching_keeps_its_field_boost
    baseline = scores(search("astrolbae", fields: ["body^1"], misspellings: { edit_distance: 2 }))
    boosted = scores(search("astrolbae", fields: ["body^3"], misspellings: { edit_distance: 2 }))

    assert_equal [document(:typo_exact).id], baseline.keys
    baseline.each do |id, score|
      assert_operator score, :>, 0
      assert_score score * 3, boosted.fetch(id)
    end
  end

  def test_boost_preserves_exclusions_and_match_all_membership
    baseline = search("mithril lantern", exclude: "entrance")
    boosted = search("mithril lantern", fields: ["body^5"], exclude: "entrance")

    assert_equal baseline.map(&:id).sort, boosted.map(&:id).sort
    assert_equal 2, boosted.total_count
    assert_equal 268, search("*", fields: ["title^0", "body^5"]).total_count
  end

  def test_highlights_and_source_projection_use_unboosted_physical_field_names
    options = { highlight: true, load: false, select: [:title], order: :id, limit: 2 }
    baseline = search("mithril lantern", **options)
    boosted = search("mithril lantern", fields: ["body^5"], **options)

    assert_equal baseline.hits.map { |hit| hit.fetch("_id") }, boosted.hits.map { |hit| hit.fetch("_id") }
    assert_equal baseline.highlights, boosted.highlights
    boosted.hits.each do |hit|
      assert_equal ["title"], hit.fetch("_source").keys
      assert_equal ["body"], hit.fetch("highlight").keys
      assert_includes hit.fetch("highlight").fetch("body").first, "<em>"
    end
  end

  def test_column_cursor_and_countless_probe_are_unchanged_by_field_boost
    baseline = search("mithril lantern", order: :id, keyset: true, limit: 1)
    boosted = search("mithril lantern", fields: ["body^10"], order: :id, keyset: true, limit: 1)

    assert_equal baseline.map(&:id), boosted.map(&:id)
    assert baseline.has_next_page?
    assert boosted.has_next_page?
    assert_equal baseline.next_cursor, boosted.next_cursor
    following = search("mithril lantern", fields: ["body^10"], order: :id, keyset: true,
      after: boosted.next_cursor, limit: 1)
    assert_equal search("mithril lantern", order: :id).map(&:id)[1, 1], following.map(&:id)
    assert_equal 4, following.total_count
  end

  def test_boosted_single_field_keeps_native_top_k_for_the_countless_probe
    statements = []
    callback = ->(*arguments) { statements << arguments.last if arguments.last[:name] == "SearchDocument Load" }
    page = search("mithril lantern", fields: ["body^1.5"], limit: 2, countless: true)
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_equal [:frequency_high, :length_short].map { |key| document(key).id }.sort, page.map(&:id).sort
      assert page.has_next_page?
    end
    statement = statements.find { |value| value[:sql].include?("_tinkick_score") }
    refute_nil statement
    plan = SearchDocument.connection.select_value(
      "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}", "Tinkick Field Boost Explain", statement.fetch(:binds)
    )

    require_production_tin_plan!
    assert_includes plan, '"Top K": "3"'
    refute_match(/"Node Type": "Sort"/, plan)
  end

  private

  def document(key)
    tinkick_test_documents(key)
  end

  def boost_documents
    [
      SearchDocument.create!(title: "Sunforge watch", body: "Sentries guard the northern tower", category: "control"),
      SearchDocument.create!(title: "Northern watch", body: "Sentries guard the sunforge tower", category: "control"),
    ]
  end

  def search(term, **options)
    SearchDocument.tinkick_search(term, misspellings: false, **options)
  end

  def scores(relation)
    relation.with_score.to_h { |record, score| [record.id, score] }
  end

  def assert_scores_equal(expected, actual)
    assert_equal expected.keys.sort, actual.keys.sort
    expected.each { |id, score| assert_score score, actual.fetch(id) }
  end

  def assert_score(expected, actual)
    assert_in_delta expected, actual, [expected.abs * 0.00001, 0.000001].max
  end
end
