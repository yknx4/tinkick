# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test/dummy/config/environment"
require "json"

# Read-only: the relevance tests own the corpus and its Rails migrations.
connection = SearchDocument.connection
raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"
raise "Run test/relevance_test.rb first" unless SearchDocument.count == 268

cases = {
  word_start: ["mithr lant", { match: :word_start }],
  word_middle: ["ithr ante", { match: :word_middle }],
  word_end: ["thril tern", { match: :word_end }],
  fuzzy_word_start: ["mitx", { match: :word_start, misspellings: true }],
  text_start: ["a mithril", { match: :text_start }],
  text_middle: ["mithril lantern", { match: :text_middle }],
  exact: ["A cafe menu", { fields: [{ title: :exact }] }],
  mixed: ["Moria", { fields: [{ title: :text_start }, :body] }],
}

reports = cases.map do |name, (term, options)|
  results = SearchDocument.tinkick_search(term, misspellings: false, limit: 5, **options)
  statements = []
  callback = ->(_event, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { results.to_a }
  statement = statements.find { |entry| entry.fetch(:sql).include?("AS _tinkick_score") }
  raise "Missing search SQL for #{name}" unless statement

  sql = statement.fetch(:sql)
  binds = statement.fetch(:binds)
  plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "Tinkick matching plans", binds)
  {
    name: name, term: term, options: options, sql: sql,
    binds: binds.map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind },
    results: results.with_score.map { |record, score| { id: record.id, title: record.title, score: score } },
    explain: JSON.parse(plan),
  }
end

report = {
  captured_at: Time.now.utc.iso8601, documents: SearchDocument.count,
  ruby: RUBY_VERSION, rails: Rails.version,
  postgres: connection.select_value("SHOW server_version"),
  tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
  method: "One EXPLAIN ANALYZE BUFFERS immediately after each query on the 268-document fixture corpus. Warm caches are possible; these plans demonstrate execution shapes, not production latency.",
  cases: reports,
}

path = File.expand_path("../docs/benchmarks/2026-09-17-match-mode-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts "Wrote #{path}"
