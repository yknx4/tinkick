# frozen_string_literal: true

require "active_record"
require "active_support/notifications"
require "json"
require "time"
require_relative "../lib/tinkick"
require_relative "../lib/tinkick/custom_spans"

# Read-only database work: synthetic page text needs TIN but no model tables,
# fixtures, optional extensions, or migrations. Only the local report is written.
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")
report = {
  captured_at: Time.now.utc.iso8601,
  method: "One warm EXPLAIN ANALYZE BUFFERS per prefix query after complete source-span mapping. Each input is one synthetic whitespace run: a followed by b characters, using the default analyzer with max_token_bytes=4 and eligible token abbb. Query elapsed_ms includes client round trips; plan execution excludes them. No model rows or application throughput are measured.",
  cases: [],
}
ActiveRecord::Base.with_connection do |connection|
  database = connection.select_value("SELECT current_database()")
  raise "Expected tinkick_test" unless database == "tinkick_test"

  report[:database] = database
  report[:tin_version] = connection.select_value("SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'tin'")
  raise "tinkick_test requires TIN" unless report[:tin_version]

  locator = Tinkick::CustomSpans.new(connection)
  [64, 256, 1_024].each do |length|
    text = "a" + "b" * (length - 1)
    statements = []
    listener = lambda do |_name, started, finished, _id, payload|
      next unless payload[:name].to_s.start_with?("Tinkick Custom Span")

      statements << { name: payload[:name], sql: payload[:sql], binds: payload[:binds], elapsed_ms: (finished - started) * 1_000 }
    end
    spans = nil
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      spans = locator.locate([text], tokens: ["abbb"],
        analysis: Tinkick::WordMatch::ANALYSIS_DEFAULTS.merge("max_token_bytes" => "4"))
    end
    raise "Unexpected source span" unless spans == [[[0, 4]]]

    prefix = statements.find { |statement| statement.fetch(:name) == "Tinkick Custom Span Prefixes" }
    raise "Expected token-policy prefix query" unless prefix

    plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{prefix.fetch(:sql)}",
      "Custom Span Plan", prefix.fetch(:binds))
    report[:cases] << {
      source_characters: length,
      native_tokens: length / 4,
      returned_spans: spans,
      queries: statements.map { |statement| statement.slice(:name, :elapsed_ms) },
      prefix_query: prefix.fetch(:sql),
      prefix_plan: JSON.parse(plan),
    }
  end
end
path = File.expand_path("../docs/benchmarks/2026-09-17-policy-highlight-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts "Wrote #{path}"
