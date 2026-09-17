# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test/dummy/config/environment"
require "json"

connection = SearchDocument.connection
raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"
raise "Run test/stress_test.rb first" unless SearchDocument.count == 10_000

cases = {
  native_relevance: ["mithril lantern", { limit: 2 }],
  relevance_countless: ["database", { where: { category: "technical" }, limit: 20, countless: true }],
  column_keyset: ["*", { where: { category: "technical" }, order: { id: :asc }, limit: 137, keyset: true }],
  category_facets: ["*", { aggs: { category: { order: { _key: :asc } } }, limit: 1 }],
}

reports = connection.transaction do
  connection.execute("SET TRANSACTION READ ONLY")
  cases.map do |name, (term, options)|
    search = SearchDocument.tinkick_search(term, misspellings: false, **options)
    statements = []
    callback = ->(_event, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      options[:aggs] ? search.aggs : search.with_score.map { |record, score| { id: record.id, score: score } }
    end
    statement = statements.find { |entry| /AS _tinkick_score|AS _tinkick_total/.match?(entry.fetch(:sql)) }
    raise "Missing SQL for #{name}" unless statement

    sql = statement.fetch(:sql)
    binds = statement.fetch(:binds)
    plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "Tinkick stress plans", binds)
    {
      name: name, term: term, options: options, sql: sql,
      binds: binds.map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind },
      results: result, explain: JSON.parse(plan),
    }
  end
end

report = {
  captured_at: Time.now.utc.iso8601, documents: SearchDocument.count,
  ruby: RUBY_VERSION, rails: Rails.version,
  postgres: connection.select_value("SHOW server_version"),
  tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
  method: "One read-only EXPLAIN ANALYZE BUFFERS immediately after each query on the fixed 10,000-document Faker Tolkien corpus (seed 314159). Warm caches are possible; no concurrency or production latency claim.",
  cases: reports,
}

path = File.expand_path("../docs/benchmarks/2026-09-17-stress-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts "Wrote #{path}"
