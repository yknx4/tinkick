# frozen_string_literal: true

require "active_record"
require "securerandom"
require "json"
require "time"
require_relative "../lib/tinkick"

ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")
class JsonFilterPlanProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
end

marker = "Recursive JSON plan #{SecureRandom.uuid}"
id_base = -(SecureRandom.random_number(2**60) + 1)
report = { captured_at: Time.now.utc.iso8601, ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s,
           fixture_rows: 100, expected_matches: 40, broad_equality_candidates: 80, plans: {} }
JsonFilterPlanProduct.with_connection do |connection|
  raise "Wrong database" unless connection.select_value("SELECT current_database()") == "tinkick_test"
  report[:postgres] = connection.select_value("SELECT version()")
  report[:tin] = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'")

  connection.transaction do
    connection.execute("SET LOCAL statement_timeout = '30s'")
    rows = 100.times.map do |index|
      metadata = if index < 40
        { tags: [[["red", "fruit"]]] }
      elsif index < 80
        { wrong: { tags: [[["red"]]] }, tags: [[["green"]]] }
      else
        { tags: [[["blue"]]] }
      end
      { id: id_base - index, name: "JSON candidate #{index}", description: marker, metadata: metadata }
    end
    JsonFilterPlanProduct.insert_all!(rows)
    scope = JsonFilterPlanProduct.where(description: marker)
    relation = Tinkick::Filter.new(JsonFilterPlanProduct).apply(scope, "metadata.tags" => "red")
    raise "Wrong match count" unless relation.count == report[:expected_matches]

    report[:index] = connection.select_value("SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid = 'index_tinkick_test_products_on_metadata'::regclass")
    report[:sql] = relation.select(:name).to_sql
    report[:plans][:natural] = JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{report[:sql]}"))
    connection.execute("SET LOCAL enable_seqscan = off")
    report[:plans][:index_eligibility] = JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{report[:sql]}"))
    raise ActiveRecord::Rollback
  end
  report[:remaining_fixture_rows] = JsonFilterPlanProduct.where(description: marker).count
end
raise "Fixture rollback failed" unless report[:remaining_fixture_rows].zero?

path = File.expand_path("../docs/benchmarks/2026-09-17-recursive-json-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(report.except(:plans).merge(execution_ms: report[:plans].transform_values { |plan| plan.first.fetch("Execution Time") }))
