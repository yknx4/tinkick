# frozen_string_literal: true

require "active_record"
require "securerandom"
require "json"
require "time"
require "faker"
require_relative "../lib/tinkick"

path = File.expand_path("../docs/benchmarks/2026-09-17-conversion-plans.json", __dir__)
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

class ConversionPlanEntry < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
  tinkick searchable: [:name], conversions: :metadata, conversions_v2: :conversion_counts
end

marker = "Conversion plan #{SecureRandom.uuid}"
lexical_marker = "conversionplan#{SecureRandom.hex(12)}"
id_base = -(SecureRandom.random_number(2**60) + 72)
expected_counts = {}
previous_random = Faker::Config.random
begin
  Faker::Config.random = Random.new(161803)
  rows = 72.times.map do |index|
    character = Faker::Fantasy::Tolkien.character
    name = if index.zero?
      ("#{lexical_marker} mithril " * 8) + "#{character} forge"
    else
      material = index < 48 ? "mithril" : "bronze"
      place = ["Moria", "Rivendell", "Gondor", "Shire"].fetch(index % 4)
      "#{lexical_marker} #{material} lantern #{character} #{place} trade ledger entry #{index}"
    end
    legacy = index >= 48 ? 100_000 : (index == 1 ? 120 : index % 5)
    modern = index >= 48 ? 200_000 : (index == 2 ? 800 : index % 7)
    metadata = index.zero? ? { "Mithril.Lantern" => 1, "MITHRIL.LANTERN" => 1 } : { "mithril.lantern" => legacy }
    metadata["mithril"] = 999_999
    counts = { "mithril.lantern" => modern, "unrelated" => 900_000 }
    if index.between?(3, 47) && index % 4 == 0
      metadata = nil
      counts = { "mithril.lantern" => nil }
      legacy = modern = 0
    end
    id = id_base - index
    expected_counts[id] = [index.zero? ? 2 : legacy, modern]
    { id: id, name: name, description: marker, metadata: metadata, conversion_counts: counts }
  end
ensure
  Faker::Config.random = previous_random
end

cases = {
  native_lexical: { options: { conversions: false, conversions_v2: false }, legacy: 0, modern: 0, winner: 0 },
  legacy: { options: {}, legacy: 1, modern: 0, winner: 1 },
  v2: { options: { conversions: false, conversions_v2: true }, legacy: 0, modern: 1, winner: 2 },
  v2_factor: { options: { conversions: false, conversions_v2: { factor: 0.25 } }, legacy: 0, modern: 0.25, winner: 2 },
  combined: { options: { conversions_v2: { factor: 0.25 } }, legacy: 1, modern: 0.25, winner: 2 },
}
expected_ids = rows.first(48).map { |row| row.fetch(:id) }.sort
report = {
  captured_at: Time.now.utc.iso8601,
  command: "direnv exec . bundle exec ruby script/explain_conversions.rb",
  ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s, faker: Faker::VERSION,
  fixture_rows: rows.length, matching_rows: expected_ids.length, seed: 161803,
  term: "#{lexical_marker} mithril", conversions_term: "Mithril.Lantern", limit: 5,
  examples: [0, 1, 2, 4, 48].map { |index| rows.fetch(index) },
  method: "One EXPLAIN ANALYZE BUFFERS per captured public search after score, winner, membership, and count checks. Unique lexical isolation; negative IDs and a description marker verify transaction rollback. No schema change, statistics refresh, or planner settings. Small-fixture timings with potentially warm caches are execution evidence, not production latency or throughput benchmarks.",
  cases: {},
}

ConversionPlanEntry.with_connection do |connection|
  raise "Wrong database" unless connection.select_value("SELECT current_database()") == "tinkick_test"
  report[:postgres] = connection.select_value("SELECT version()")
  report[:tin] = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'")
  raise "TIN extension required" unless report[:tin]
  owned_ids = rows.map { |row| row.fetch(:id) }
  raise "Refusing to reuse existing IDs" if ConversionPlanEntry.where(id: owned_ids).exists?
  raise "Refusing to reuse an existing marker" if ConversionPlanEntry.where(description: marker).exists?

  begin
    connection.transaction do
      connection.execute("SET LOCAL statement_timeout = '30s'")
      ConversionPlanEntry.insert_all!(rows)
      common = { fields: [:name], misspellings: false, conversions_term: report[:conversions_term] }
      baseline = ConversionPlanEntry.search(report[:term], **common, conversions: false, conversions_v2: false, limit: rows.length)
        .with_score.to_h { |record, score| [record.id, score] }
      raise "Wrong native matching IDs" unless baseline.keys.sort == expected_ids

      cases.each do |label, specification|
        page = ConversionPlanEntry.search(report[:term], **common, **specification.fetch(:options), limit: report[:limit])
        statements = []
        callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
        pairs = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { page.with_score.to_a }
        expected_winner = rows.fetch(specification.fetch(:winner)).fetch(:id)
        raise "Wrong winner for #{label}" unless pairs.first&.first&.id == expected_winner
        ids = page.limit(rows.length).pluck(:id).sort
        raise "Changed matching IDs for #{label}" unless ids == expected_ids
        raise "Wrong count for #{label}" unless page.total_count == expected_ids.length

        pairs.each do |record, score|
          legacy, modern = expected_counts.fetch(record.id)
          expected_score = baseline.fetch(record.id) + legacy * specification.fetch(:legacy) + modern * specification.fetch(:modern)
          tolerance = [expected_score.abs, 1].max * 0.000001
          raise "Wrong additive score for #{label}: #{record.id}" unless (score - expected_score).abs <= tolerance
        end

        statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_score") }
        raise "Scored search query not captured" unless statement
        sql = statement.fetch(:sql)
        plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}",
          "Tinkick conversion plan", statement.fetch(:binds))
        binds = statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
        report[:cases][label] = {
          options: specification.fetch(:options), count: ids.length, matching_ids: ids,
          native_top_k: plan.match?(/"Top K"\s*:\s*"5"/),
          results: pairs.map do |record, score|
            { id: record.id, name: record.name, score: score, native_score: baseline.fetch(record.id),
              fixture_counts: expected_counts.fetch(record.id) }
          end,
          sql: sql, binds: binds, plan: JSON.parse(plan),
        }
      end
      raise ActiveRecord::Rollback
    end
  ensure
    report[:remaining_fixture_ids] = ConversionPlanEntry.where(id: owned_ids).count
    report[:remaining_fixture_rows] = ConversionPlanEntry.where(description: marker).count
    raise "Fixture rollback failed" unless report[:remaining_fixture_ids].zero? && report[:remaining_fixture_rows].zero?
  end
end

File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(report.slice(:fixture_rows, :matching_rows, :remaining_fixture_ids, :remaining_fixture_rows).merge(
  cases: report[:cases].transform_values do |entry|
    { winner: entry[:results].first.fetch(:id), execution_ms: entry[:plan].first.fetch("Execution Time") }
  end,
))
