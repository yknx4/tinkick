# frozen_string_literal: true

require_relative "support/catalog_helper"
require_relative "support/catalog_sql"

class CatalogCollapseTest < CatalogIntegrationTest
  def test_preferred_enriched_edition_retains_best_group_score_and_tenant_filter
    candidates = search("Hobbit", where: { collection_id: 1 }, block: CatalogSql.method(:rank))
    winner = candidates.with_score.to_a.first
    assert_equal entry(:hobbit).id, winner.first.id
    grouped = collapsed
    assert_equal entry(:enriched).id, grouped.first.id
    assert_in_delta winner.last, grouped.with_score.to_a.first.last, 0.001
    assert_equal candidates.total_count - 1, grouped.total_count
    assert_equal grouped.map(&:group_key).uniq, grouped.map(&:group_key)
    refute_includes grouped.map(&:id), entry(:foreign).id
    assert_equal grouped.map(&:id), collapsed(load: false).map(&:id)
  end

  def test_without_enriched_the_best_scoring_edition_is_returned
    entry(:enriched).update!(has_extended_metadata: false)
    assert_equal entry(:hobbit).id, collapsed.first.id
  end

  def test_collapse_precedes_pagination_and_keeps_complete_pages
    all = collapsed.map(&:id)
    first = collapsed(limit: 2, countless: true)
    second = collapsed(page: 2, per_page: 2, countless: true)
    assert_equal all.first(2), first.map(&:id)
    assert first.has_next_page?
    assert_equal all.drop(2).first(2), second.map(&:id)
    refute second.has_next_page?
    assert_equal all.length, first.total_count
  end

  def test_enriched_and_cover_filters_apply_before_edition_selection
    assert_equal [entry(:enriched).id], collapsed(where: { collection_id: 1, has_extended_metadata: true }).map(&:id)
    assert_equal [entry(:hobbit).id, entry(:guide).id], collapsed(where: { collection_id: 1, has_image: true }).map(&:id)
  end

  private

  def collapsed(**options)
    search("Hobbit", where: { collection_id: 1 }, block: ->(relation) { CatalogSql.collapse(CatalogSql.rank(relation)) }, **options)
  end
end
