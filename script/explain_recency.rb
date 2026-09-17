# frozen_string_literal: true

require "active_record"
require "securerandom"
require "json"
require "time"
require "faker"
require_relative "../lib/tinkick"

path = File.expand_path("../docs/benchmarks/2026-09-17-recency-plans.json", __dir__)
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

class RecencyPlanEntry < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
  tinkick searchable: [:name]
end

marker = SecureRandom.uuid
lexical_marker = "recencyplan#{marker.delete('-')}"
id_base = -(SecureRandom.random_number(2**60) + 96)
origin = Time.utc(2026, 9, 17, 12)
previous_random = Faker::Config.random
begin
  Faker::Config.random = Random.new(271828)
  rows = 96.times.map do |index|
    character = Faker::Fantasy::Tolkien.character
    name = case index
    when 0 then ("#{lexical_marker} mithril lantern " * 10) + "#{character} ancient ledger"
    when 1 then "#{lexical_marker} mithril lantern #{character}"
    else
      material = index < 64 ? "mithril" : "bronze"
      place = ["Moria", "Rivendell", "Gondor", "Shire"].fetch(index % 4)
      "#{lexical_marker} #{material} lantern #{character} #{place} ledger entry #{index} account of mountain weather and river trade"
    end
    age = case index
    when 0 then 365 * 86_400
    when 1 then Rational(1, 2000)
    when 2 then Rational(3, 2000)
    else (index - 1) * 7 * 86_400
    end
    { id: id_base - index, name: name, code: marker, recorded_at: origin - age,
      recorded_on: (origin - age).to_date, price: index + 1, ratio: 1 }
  end
ensure
  Faker::Config.random = previous_random
end

cases = {
  native_lexical: {},
  recency_seven_days: { boost_by_recency: { recorded_at: { origin: origin, scale: "7d" } } },
  recency_submillisecond: { boost_by_recency: { recorded_at: { origin: origin, scale: "1500 microseconds" } } },
}
expected_ids = rows.first(64).map { |row| row.fetch(:id) }.sort
report = {
  captured_at: Time.now.utc.iso8601,
  command: "direnv exec . bundle exec ruby script/explain_recency.rb",
  ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s, faker: Faker::VERSION,
  fixture_rows: rows.length, matching_rows: expected_ids.length, seed: 271828,
  term: "#{lexical_marker} mithril lantern", origin: origin.iso8601(6), limit: 5,
  expected_native_winner: rows.first.fetch(:id), expected_recency_winner: rows.fetch(1).fetch(:id),
  examples: rows.first(3).map { |row| row.merge(recorded_at: row.fetch(:recorded_at).iso8601(6)) },
  method: "One EXPLAIN ANALYZE BUFFERS per captured public search after result-ID and score checks. No DDL, forced planner settings, or statistics refresh. Transaction-owned rows roll back. A unique lexical marker isolates search matches; UUID and negative IDs verify ownership/cleanup. Existing statistics and potentially warm caches make this a small execution example, not a throughput or production latency benchmark.",
  cases: {},
}

RecencyPlanEntry.with_connection do |connection|
  raise "Wrong database" unless connection.select_value("SELECT current_database()") == "tinkick_test"
  report[:postgres] = connection.select_value("SELECT version()")
  report[:tin] = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'")
  raise "TIN extension required" unless report[:tin]

  owned_ids = rows.map { |row| row.fetch(:id) }
  raise "Refusing to reuse existing IDs" if RecencyPlanEntry.where(id: owned_ids).exists?
  raise "Refusing to reuse an existing marker" if RecencyPlanEntry.where(code: marker).exists?

  begin
    connection.transaction do
      connection.execute("SET LOCAL statement_timeout = '30s'")
      RecencyPlanEntry.insert_all!(rows)
      common = { fields: [:name], misspellings: false }
      baseline = RecencyPlanEntry.search(report[:term], **common, limit: rows.length)
        .with_score.to_h { |record, score| [record.id, score] }
      raise "Wrong native matching IDs" unless baseline.keys.sort == expected_ids

      cases.each do |label, options|
        page = RecencyPlanEntry.search(report[:term], **common, **options, limit: report[:limit])
        statements = []
        callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
        pairs = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { page.with_score.to_a }
        expected_winner = label == :native_lexical ? report[:expected_native_winner] : report[:expected_recency_winner]
        raise "Unexpected winner for #{label}" unless pairs.first&.first&.id == expected_winner
        ids = page.limit(rows.length).pluck(:id).sort
        raise "Changed matching IDs for #{label}" unless ids == expected_ids
        raise "Wrong count for #{label}" unless page.total_count == expected_ids.length

        scale_seconds = label == :recency_submillisecond ? 0.0015 : 7 * 86_400
        pairs.each do |record, score|
          multiplier = label == :native_lexical ? 1 : 0.5**(((origin - record.recorded_at) / scale_seconds)**2)
          expected_score = baseline.fetch(record.id) * multiplier
          tolerance = [expected_score.abs, 1].max * 0.00001
          raise "Unexpected score for #{label}: #{record.id}" unless (score - expected_score).abs <= tolerance
        end

        statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_score") }
        raise "Scored search query not captured" unless statement
        sql = statement.fetch(:sql)
        plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}",
          "Tinkick recency plan", statement.fetch(:binds))
        native_top_k = plan.match?(/"Top K"\s*:\s*"5"/)
        binds = statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
        interval_queries = statements.filter_map do |entry|
          entry.fetch(:sql) if entry.fetch(:sql).start_with?("SELECT EXTRACT(EPOCH FROM ")
        end
        expected_parses = label == :native_lexical ? 0 : 1
        raise "Unexpected interval parse count" unless interval_queries.length == expected_parses
        report[:cases][label] = {
          options: options, count: ids.length, matching_ids: ids,
          native_top_k: native_top_k,
          interval_parse_sql: interval_queries,
          results: pairs.map { |record, score| { id: record.id, name: record.name, recorded_at: record.recorded_at.iso8601(6), score: score } },
          sql: sql, binds: binds, plan: JSON.parse(plan),
        }
      end
      raise ActiveRecord::Rollback
    end
  ensure
    report[:remaining_fixture_ids] = RecencyPlanEntry.where(id: owned_ids).count
    report[:remaining_fixture_rows] = RecencyPlanEntry.where(code: marker).count
    raise "Fixture rollback failed" unless report[:remaining_fixture_ids].zero? && report[:remaining_fixture_rows].zero?
  end
end

File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(report.slice(:fixture_rows, :matching_rows, :remaining_fixture_ids, :remaining_fixture_rows).merge(
  cases: report[:cases].transform_values do |entry|
    { winner: entry[:results].first.fetch(:id), interval_queries: entry[:interval_parse_sql].length,
      execution_ms: entry[:plan].first.fetch("Execution Time") }
  end,
))
