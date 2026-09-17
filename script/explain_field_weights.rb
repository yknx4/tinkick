# frozen_string_literal: true

require_relative "../lib/tinkick"
require "json"
require "time"

# Read-only: relevance tests own the corpus, indexes, and fixture loading.
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")
raise "Wrong database" unless ActiveRecord::Base.connection.select_value("SELECT current_database()") == "tinkick_test"

class WeightedBoostProbe < ActiveRecord::Base
  self.table_name = "tinkick_test_documents"
  tinkick searchable: [:title, :body], default_fields: [:body]
end

connection = WeightedBoostProbe.connection
raise "Run test/relevance_test.rb first" unless WeightedBoostProbe.count == 268
cases = ["body^1", "body^20000"].map do |field|
  statements = []
  callback = ->(*arguments) { statements << arguments.last if arguments.last[:name] == "WeightedBoostProbe Load" }
  options = { fields: [field], misspellings: false, countless: true, limit: 2 }
  page = WeightedBoostProbe.tinkick_search("mithril lantern", **options)
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { page.to_a }
  statement = statements.find { |entry| entry[:sql].include?("_tinkick_score") }
  raise "Search query not captured" unless statement

  plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
    "Tinkick Weighted SQL Explain", statement.fetch(:binds))
  binds = statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
  { term: "mithril lantern", options: options, sql: statement.fetch(:sql), binds: binds,
   result_ids: page.map(&:id), plan: JSON.parse(plan) }
end
artifact = { captured_at: Time.now.utc.iso8601, ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s,
            postgres: connection.select_value("SELECT version()"),
            tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
            rows: WeightedBoostProbe.count, cases: cases,
            method: "One warm EXPLAIN ANALYZE BUFFERS per query over the 268-document relevance fixture corpus. These plans establish the native top-k versus SQL group/sort execution shapes; timings do not establish relative performance or production latency.",
            command: "direnv exec . bundle exec ruby script/explain_field_weights.rb" }
path = File.expand_path("../docs/benchmarks/2026-09-17-field-weight-plans.json", __dir__)
File.write(path, JSON.pretty_generate(artifact) + "\n")
puts JSON.generate(rows: artifact[:rows], cases: cases.map { |entry| { fields: entry[:options][:fields], result_ids: entry[:result_ids], execution_time_ms: entry[:plan].first["Execution Time"] } })
