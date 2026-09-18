# frozen_string_literal: true

require_relative "support/catalog_helper"

class CatalogSearchTest < CatalogIntegrationTest
  def test_title_author_combined_partial_unicode_and_alternate_titles
    assert_equal 136, CatalogEntry.count
    assert_equal [entry(:hobbit).id, entry(:foreign).id], search("Hobbit", match: :phrase).where(title: "The Hobbit").map(&:id).sort
    assert_includes search("bbit", match: :word_middle).map(&:id), entry(:hobbit).id
    assert_includes search("Tolkien", fields: [:creator_name]).map(&:id), entry(:hobbit).id
    assert_equal [entry(:guide).id], search("Hobbit Bilbo", fields: [:search_text]).map(&:id)
    assert_equal [entry(:unicode).id], search("Númenor").map(&:id)
    assert_equal [entry(:alternate).id], search("Communauté").map(&:id)
    assert_empty search("Hobbit", fields: [:creator_name])
    refute_includes search("Hobbit").map(&:id), entry(:background_0).id
  end

  def test_native_typo_fallback_and_disabling_it
    assert_empty search("Hobbt", match: :word_middle)
    fuzzy = search("Hobbt", misspellings: { below: 5, prefix_length: 3 })
    assert fuzzy.misspellings?
    assert_includes fuzzy.map(&:id), entry(:hobbit).id
    assert_empty search("Xobbit", misspellings: { prefix_length: 3 })
    # The future app keeps fast/profanity policy and explicitly passes false.
    assert_empty search("Hobbt", misspellings: false)
    partial = search("bbit", match: :word_middle)
    assert_operator partial.total_count, :>=, 5
    refute partial.misspellings?
  end

  def test_safety_reading_integrity_cover_and_enriched_filters
    safe = search("Hobbit", where: { restricted_content: false, minimum_age: { gte: 0 } })
    refute_includes safe.map(&:id), entry(:unsafe).id
    refute_includes safe.map(&:id), entry(:age).id
    assert_equal [entry(:hobbit).id, entry(:guide).id], safe.where(has_image: true).map(&:id).sort
    assert_equal [entry(:enriched).id, entry(:foreign).id], safe.where(has_extended_metadata: true).map(&:id).sort
  end

  def test_collection_ids_status_groups_and_level_arrays
    local = search("Hobbit", where: { collection_id: 1 })
    refute_includes local.map(&:id), entry(:foreign).id
    assert_includes search("Hobbit", where: { collection_id: [1, 2] }).map(&:id), entry(:foreign).id
    assert_equal [entry(:hobbit).id, entry(:guide).id], local.where(status: [:approved, :rejected]).map(&:id).sort
    assert_equal [entry(:enriched).id], local.where(status: [:pending, :review], pending_levels: { exists: true }).map(&:id)
    { approved_levels: :hobbit, rejected_levels: :guide, pending_levels: :enriched }.each do |field, fixture|
      assert_equal [entry(fixture).id], local.where(field => [4]).map(&:id)
    end
    assert_empty local.where(approved_levels: [12])
  end

  def test_boosts_pagination_raw_loading_and_eager_loading
    boosted = search("Hobbit", where: { collection_id: 1 }, boost_where: { has_verified_identifier: { value: true, factor: 50 } },
      boost_by: { popularity: { factor: 100 } })
    assert_equal entry(:hobbit).id, boosted.first.id
    ordered = search("Hobbit", where: { collection_id: 1 }, order: { id: :asc })
    assert_equal ordered.limit(2).map(&:id), ordered.per_page(2).page(1).map(&:id)
    assert_equal ordered.to_a.drop(2).first(2).map(&:id), ordered.per_page(2).page(2).map(&:id)
    assert_equal ordered.map(&:id), ordered.load(false).map(&:id)
    assert ordered.includes(:editions).first.association(:editions).loaded?
    assert_equal 2, ordered.countless.limit(2).size
    assert ordered.countless.limit(2).has_next_page?
  end
end
