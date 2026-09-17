# frozen_string_literal: true

require "active_record"
require "securerandom"
require "json"
require "time"
require "faker"
require_relative "../lib/tinkick"

ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

class AggregationPlanEntry < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  tinkick searchable: [:name]
end

marker = "Aggregation plan #{SecureRandom.uuid}"
lexical_marker = "aggregationplan#{SecureRandom.hex(12)}"
id_base = -(SecureRandom.random_number(2**60) + 96)
tags = [nil, [], [nil], ["Moria", "Moria", nil], ["Rivendell", "Gondor"], ["Shire"], ["Moria", "Rivendell"], ["Gondor", "Shire"]]
ratings = [nil, [], [nil], [2, 2, nil], [4], [6], [8], [10]]
previous_random = Faker::Config.random
begin
  Faker::Config.random = Random.new(271828)
  rows = 96.times.map do |index|
    material = index < 64 ? "mithril" : "bronze"
    { id: id_base - index,
      name: "#{lexical_marker} #{material} #{Faker::Fantasy::Tolkien.character} inventory entry #{index}",
      description: marker, tags: index < 64 ? tags.fetch(index % 8) : ["Unrelated"],
      ratings: index < 64 ? ratings.fetch(index % 8) : [1_000_000] }
  end
ensure
  Faker::Config.random = previous_random
end

cases = {
  native_terms: { options: { field: :tags }, buckets: { "Gondor" => 16, "Moria" => 16, "Rivendell" => 16, "Shire" => 16 }, other: 0 },
  exact_filter: { options: { field: :tags, include: ["Moria", "Rivendell", "Gondor"], exclude: ["Gondor"], limit: 1 }, buckets: { "Moria" => 16 }, other: 16 },
  native_regexp: { options: { field: :tags, include: "(?i)^(moria|rivendell)$" }, buckets: { "Moria" => 16, "Rivendell" => 16 }, other: 0 },
  missing_terms: { options: { field: :tags, missing: "Unknown" }, buckets: { "Unknown" => 24, "Gondor" => 16, "Moria" => 16, "Rivendell" => 16, "Shire" => 16 }, other: 0 },
  missing_metric: { options: { sum: { field: :ratings, missing: 5 } }, value: 376.0 },
}
report = {
  captured_at: Time.now.utc.iso8601, command: "direnv exec . bundle exec ruby script/explain_aggregation_options.rb",
  ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s, faker: Faker::VERSION, seed: 271828,
  fixture_rows: rows.length, matching_rows: 64, term: "#{lexical_marker} mithril",
  method: "One EXPLAIN ANALYZE BUFFERS per public aggregation after exact bucket/metric and record-membership checks. No DDL, statistics refresh, or forced planner settings. Transactional Faker Tolkien rows roll back. Small fixtures and potentially warm caches do not establish production latency or throughput.",
  cases: {},
}

AggregationPlanEntry.with_connection do |connection|
  raise "Wrong database" unless connection.select_value("SELECT current_database()") == "tinkick_test"
  report[:postgres] = connection.select_value("SHOW server_version")
  report[:tin] = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'")
  raise "TIN extension required" unless report[:tin]
  owned_ids = rows.map { |row| row.fetch(:id) }
  raise "Refusing to reuse existing IDs" if AggregationPlanEntry.where(id: owned_ids).exists?
  raise "Refusing to reuse an existing marker" if AggregationPlanEntry.where(description: marker).exists?

  begin
    connection.transaction do
      connection.execute("SET LOCAL statement_timeout = '30s'")
      AggregationPlanEntry.insert_all!(rows)
      expected_ids = rows.first(64).map { |row| row.fetch(:id) }.sort
      cases.each do |label, specification|
        page = AggregationPlanEntry.search(report[:term], misspellings: false, limit: rows.length,
          aggs: { values: specification.fetch(:options) })
        statements = []
        callback = ->(_event, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
        result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { page.aggs.fetch("values") }
        if specification.key?(:buckets)
          buckets = result.fetch("buckets").to_h { |bucket| [bucket.fetch("key"), bucket.fetch("doc_count")] }
          raise "Wrong buckets for #{label}" unless buckets == specification.fetch(:buckets)
          raise "Wrong remaining count for #{label}" unless result.fetch("sum_other_doc_count") == specification.fetch(:other)
        else
          raise "Wrong metric for #{label}" unless result.fetch("value") == specification.fetch(:value)
        end
        raise "Changed record membership for #{label}" unless page.pluck(:id).sort == expected_ids
        statement = statements.find { |entry| entry.fetch(:sql).include?("_tinkick_document_id") }
        raise "Missing aggregation SQL for #{label}" unless statement

        sql = statement.fetch(:sql)
        plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "Tinkick aggregation plan", statement.fetch(:binds))
        binds = statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
        report[:cases][label] = { options: specification.fetch(:options), result: result, sql: sql, binds: binds, plan: JSON.parse(plan) }
      end
      raise ActiveRecord::Rollback
    end
  ensure
    report[:remaining_fixture_ids] = AggregationPlanEntry.where(id: owned_ids).count
    report[:remaining_fixture_rows] = AggregationPlanEntry.where(description: marker).count
    raise "Fixture rollback failed" unless report[:remaining_fixture_ids].zero? && report[:remaining_fixture_rows].zero?
  end
end

File.write(File.expand_path("../docs/benchmarks/2026-09-17-aggregation-options-plans.json", __dir__), JSON.pretty_generate(report) + "\n")
puts JSON.generate(report.slice(:fixture_rows, :matching_rows, :remaining_fixture_ids, :remaining_fixture_rows).merge(
  cases: report[:cases].transform_values { |entry| { result: entry[:result], execution_ms: entry[:plan].first.fetch("Execution Time") } },
))
