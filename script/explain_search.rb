# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test/dummy/config/environment"
require "json"
require "fileutils"
require "action_dispatch/testing/integration"

# Read-only evidence collection. Run the Rails/relevance tests first to load
# their dedicated fixture tables. This script never migrates or seeds data.
connection = SearchDocument.connection
database = connection.select_value("SELECT current_database()")
raise "Expected tinkick_test" unless database == "tinkick_test"
raise "Run test/relevance_test.rb first" unless SearchDocument.count == 268

cursor = SearchDocument.tinkick_search("mithril lantern", misspellings: false, keyset: true, limit: 2).next_cursor
all_cursor = SearchDocument.tinkick_search("*", keyset: true, limit: 2).next_cursor
cases = {
  ranked: ["mithril lantern", { limit: 2 }],
  countless: ["mithril lantern", { limit: 2, countless: true }],
  offset: ["mithril lantern", { limit: 2, offset: 2 }],
  keyset: ["mithril lantern", { limit: 2, keyset: true, after: cursor }],
  multiple_fields: ["Moria Balrog", { fields: [:title, :body], limit: 2 }],
  keyset_match_all: ["*", { limit: 2, keyset: true, after: all_cursor }],
}

reports = cases.map do |name, (term, options)|
  relation = SearchDocument.tinkick_search(term, misspellings: false, **options)
  statements = []
  callback = ->(_event, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.to_a }
  statement = statements.find { |entry| entry.fetch(:sql).include?("_tinkick_score") }
  raise "Missing search SQL for #{name}" unless statement

  sql = statement.fetch(:sql)
  binds = statement.fetch(:binds)
  plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "Tinkick plan evidence", binds)
  {
    name: name, term: term, options: options, sql: sql,
    binds: binds.map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind },
    results: relation.with_score.map { |record, score| { id: record.id, title: record.title, score: score } },
    explain: JSON.parse(plan),
  }
end

session = ActionDispatch::Integration::Session.new(Rails.application)
session.get("/characters.json", params: { q: "Hnuleth" })
raise "Rails search request failed" unless session.response.status == 200

report = {
  captured_at: Time.now.utc.iso8601,
  database: database, documents: SearchDocument.count,
  ruby: RUBY_VERSION, rails: Rails.version,
  postgres: connection.select_value("SHOW server_version"),
  tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
  method: "One EXPLAIN ANALYZE BUFFERS execution immediately after each normal query; cache may be warm. No benchmark or production latency claim.",
  cases: reports,
  http_example: {
    path: "/characters.json", params: { q: "Hnuleth" },
    status: session.response.status, body: JSON.parse(session.response.body),
  },
}

path = File.expand_path("../docs/benchmarks/2026-09-17-search-plans.json", __dir__)
FileUtils.mkdir_p(File.dirname(path))
File.write(path, JSON.pretty_generate(report) + "\n")
puts "Wrote #{path}"
