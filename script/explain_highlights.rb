# frozen_string_literal: true

require "active_record"
require "json"
require_relative "../lib/tinkick"

# Read-only: the integration tests own the table and indexes.
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

class HighlightPlanProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  tinkick searchable: [:name]
end

HighlightPlanProduct.with_connection do |connection|
  raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"

  texts = Array.new(20) do |index|
    "Aragorn surveys Gondor near the river. Argaorn is a misspelled name. Unrelated pottery and astronomy notes #{index}. " * 4
  end
  statements = []
  listener = lambda do |*arguments|
    event = arguments.last
    if ["Tinkick Highlight", "Tinkick Text Highlight"].include?(event[:name])
      statements << event.slice(:name, :sql, :binds)
    end
  end
  ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
    query = Tinkick::QueryText.new(connection).compile("argaorn", misspellings: { edit_distance: 2 })
    highlighted = Tinkick::Highlighter.new(connection).fragments_many(texts, query, fragment_size: 80)
    unless highlighted.length == texts.length && highlighted.all? { |fragments| ["<em>Aragorn</em>", "<em>Argaorn</em>"].all? { |match| fragments.join.include?(match) } }
      raise "Expected native fuzzy highlights for both supplied spellings in every page row"
    end
    matching = Tinkick::TextMatch.new(HighlightPlanProduct).highlight_matches(texts, "argaorn", match: :text_middle, misspellings: false)
    raise "Expected each supplied page field to match the native SQL substring" unless matching == texts
  end
  plans = statements.map do |event|
    raw = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{event.fetch(:sql)}", "Tinkick Highlight Plan", event.fetch(:binds))
    { name: event.fetch(:name), sql: event.fetch(:sql), plan: JSON.parse(raw).first }
  end
  report = {
    captured_at: Time.now.utc.iso8601, ruby: RUBY_VERSION, active_record: ActiveRecord.version.to_s,
    postgres: connection.select_value("SHOW server_version"),
    tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
    page_rows: texts.length, source_characters: texts.sum(&:length),
    method: "One warm EXPLAIN ANALYZE BUFFERS per page helper, using synthetic text supplied by this script. No model search or model-table scan is measured; this is not throughput or application latency.",
    plans: plans,
  }
  path = File.expand_path("../docs/benchmarks/2026-09-17-highlight-plans.json", __dir__)
  File.write(path, JSON.pretty_generate(report) + "\n")
  puts "Wrote #{path}"
end
