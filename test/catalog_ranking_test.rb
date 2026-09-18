# frozen_string_literal: true

require_relative "support/catalog_helper"
require_relative "support/catalog_sql"

class CatalogRankingTest < CatalogIntegrationTest
  def test_multiplicative_flags_and_popularity_keep_native_relevance
    base = search("Hobbit", where: { collection_id: 1 }, load: false)
    scores = base.with_score.to_h { |record, score| [record.id, score] }
    ranked = search("Hobbit", where: { collection_id: 1 }, load: false, block: CatalogSql.method(:rank))
    assert_equal entry(:hobbit).id, ranked.first.id
    actual = ranked.with_score.to_h { |record, score| [record.id, score] }
    assert_in_epsilon scores.fetch(entry(:hobbit).id) * 50 * 30 * 15 * Math.log(1202), actual.fetch(entry(:hobbit).id), 1e-6
    assert_in_delta scores.fetch(entry(:enriched).id) * 5 * Math.log(2), actual.fetch(entry(:enriched).id), 0.001
    assert_equal base.total_count, ranked.total_count
    assert_equal actual, ranked.select(:title).with_score.to_h { |record, score| [record.id, score] }
  end

  def test_exact_title_bonus_is_added_after_capped_sum_and_logarithmic_popularity
    entry(:hobbit).update!(has_extended_metadata: true, popularity: 2_000_000_000)
    base_score = search("Hobbit", where: { id: entry(:hobbit).id }).with_score.to_a.first.last
    ranked = search("Hobbit", where: { collection_id: 1 }, block: ->(relation) { CatalogSql.rank(relation, exact_title: "the hobbit") })
    assert_equal entry(:hobbit).id, ranked.first.id
    assert_in_delta base_score * 10 + 1000, ranked.with_score.to_a.first.last, 0.001
    assert_operator ranked.with_score.to_a.first.last, :>, 1000
    guide_score = search("Hobbit", where: { id: entry(:guide).id }).with_score.to_a.first.last
    actual = ranked.with_score.to_h { |record, score| [record.id, score] }
    assert_in_delta guide_score * (3 + Math.log10(1001)), actual.fetch(entry(:guide).id), 0.001
  end

  def test_exact_title_parameter_is_bound_and_metadata_only_omits_its_own_boost
    ranked = search("Hobbit", where: { id: entry(:enriched).id }, block: ->(relation) { CatalogSql.rank(relation, metadata_only: true) })
    original = search("Hobbit", where: { id: entry(:enriched).id }).with_score.to_a.first.last
    assert_in_delta original * Math.log(2), ranked.with_score.to_a.first.last, 0.001
    hostile = "the hobbit' OR 1=1 --"
    ranked = search("Hobbit", block: ->(relation) { CatalogSql.rank(relation, exact_title: hostile) })
    assert ranked.with_score.all? { |_record, score| score < 1000 }
  end
end
