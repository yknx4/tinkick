# frozen_string_literal: true

require_relative "support/catalog_helper"
require_relative "support/catalog_sql"
require "digest"

class CatalogApplicationTest < CatalogIntegrationTest
  def test_http_hook_preserves_collection_scope_combined_search_and_pages
    get "/catalog.json", params: { q: "Hobbit Tolkien", collection_id: 1, field: "search_text", per_page: 1 }
    assert_response :success
    result = response.parsed_body
    assert_equal [entry(:hobbit).id], result.fetch("entries").map { |row| row.fetch("id") }
    assert result.fetch("has_next_page")
    get "/catalog.json", params: { q: "Hobbit Tolkien", collection_id: 1, field: "search_text", per_page: 1, page: 2 }
    assert_response :success
    assert_equal [entry(:enriched).id], response.parsed_body.fetch("entries").map { |row| row.fetch("id") }
    refute response.parsed_body.fetch("has_next_page")
  end

  def test_http_treats_query_text_literally_and_validates_field_choices
    get "/catalog.json", params: { q: "Hobbit' OR 1=1 --", collection_id: 1 }
    assert_response :success
    assert_empty response.parsed_body.fetch("entries")
    get "/catalog.json", params: { q: "Hobbit", collection_id: 1, field: "title; DROP TABLE entries" }
    assert_response :bad_request
    assert_equal 136, CatalogEntry.count
  end

  def test_statement_timeout_cancels_search_and_savepoint_restores_connection
    connection = CatalogEntry.connection
    previous = connection.select_value("SHOW statement_timeout")
    error = assert_raises(ActiveRecord::QueryCanceled) do
      CatalogEntry.transaction(requires_new: true) do
        connection.execute("SET LOCAL statement_timeout = '100ms'")
        search("Hobbit", block: ->(relation) { relation.joins("CROSS JOIN (SELECT pg_sleep(1)) AS delay") }).to_a
      end
    end
    assert_equal "57014", error.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
    assert_equal previous, connection.select_value("SHOW statement_timeout")
    assert_includes search("Hobbit").map(&:id), entry(:hobbit).id
  end

  def test_rails_cache_keys_separate_query_variants_and_invalidation_refreshes_results
    cache = ActiveSupport::Cache::MemoryStore.new
    base = search("Hobbit", where: { collection_id: 1 }, load: false, order: { id: :asc })
    variants = [base, base.page(2).per_page(1), base.where(collection_id: 2), base.where(has_image: true),
      search("Hobbit", block: ->(relation) { CatalogSql.rank(relation, exact_title: "the hobbit") })]
    keys = variants.map { |query| cache_key(query) }
    assert_equal keys.length, keys.uniq.length
    assert keys.all? { |key| key.start_with?("tinkick:catalog:v1:") }
    fetch = -> { cache.fetch(keys.first, expires_in: 1.minute) { base.to_relation.map(&:attributes) } }
    original = fetch.call
    entry(:hobbit).update!(title: "A revised Hobbit edition")
    assert_equal original, fetch.call
    cache.delete(keys.first)
    assert_equal "A revised Hobbit edition", fetch.call.first.fetch("title")
  end

  private

  def cache_key(query)
    "tinkick:catalog:v1:#{Digest::SHA256.hexdigest(query.to_relation.to_sql)}"
  end
end
