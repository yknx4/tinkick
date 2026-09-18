# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test/dummy/config/environment"
require_relative "../test/support/catalog_sql"
require "json"

# Read-only: load the synthetic catalog fixtures by running their tests first.
connection = CatalogEntry.connection
raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"
raise "Run test/catalog_search_test.rb first" unless CatalogEntry.count == 136
raise "Capture production TIN plans, not Lead plans" if ENV["TINKICK_TEST_BACKEND"] == "lead"

cases = {
  native: nil,
  capped_exact: ->(relation) { CatalogSql.rank(relation, exact_title: "the hobbit") },
  grouped_metadata: ->(relation) { CatalogSql.collapse(CatalogSql.rank(relation)) },
}.map do |name, transform|
  query = CatalogEntry.where(collection_id: 1).tinkick_search("Hobbit", misspellings: false,
    limit: 2, block: transform).to_relation
  sql = query.to_sql
  { name: name, sql: sql,
    results: query.map { |entry| entry.attributes.slice("id", "title", "group_key", "has_extended_metadata", "_tinkick_score") },
    explain: connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}") }
end
report = {
  captured_at: Time.now.utc.iso8601, database: "tinkick_test", entries: CatalogEntry.count,
  postgres: connection.select_value("SHOW server_version"),
  tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
  command: "direnv exec . bundle exec ruby script/explain_catalog.rb",
  method: "Read-only queries on synthetic fixtures; one warm plan per shape, not a production benchmark.",
  cases: cases,
}
path = File.expand_path("../docs/benchmarks/2026-09-17-catalog-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts path
