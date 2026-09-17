# frozen_string_literal: true

require "active_record"
require "securerandom"
require "json"
require "time"
require "faker"
require_relative "../lib/tinkick"

ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")
class RegexpPlanProduct < ActiveRecord::Base
  self.table_name = "tinkick_test_products"
end

marker = "Regexp plan #{SecureRandom.uuid}"
id_base = -(SecureRandom.random_number(2**60) + 240)
previous_random = Faker::Config.random
begin
  Faker::Config.random = Random.new(314159)
  rows = 240.times.map do |index|
    material = index < 60 ? "mithril" : "bronze"
    topic = if index < 45 || (60...120).cover?(index)
      "Moria archive"
    else
      ["Rivendell recipe collection", "Gondor travel ledger", "Shire planting calendar", "Orthanc astronomy notes"].fetch(index % 4)
    end
    topic += " and Balrog accounts" if (30...45).cover?(index)
    name = "#{material} #{topic}: #{Faker::Fantasy::Tolkien.character} records catalog entry #{index}."
    if index % 20 == 0
      name += "\n" + ("The archivist compares old maps, weather observations, trade records, and a poem about 🧙 distant journeys. " * 16)
    end
    { id: id_base - index, name: name, description: marker }
  end
ensure
  Faker::Config.random = previous_random
end

ordinary = ".*Moria.*"
advanced = ".*Moria.*&~(.*Balrog.*)"
patterns = { native_control: nil, ordinary_all: ordinary, advanced_all: advanced,
             ordinary_native: ordinary, advanced_native: advanced }
lengths = rows.map { |row| row.fetch(:name).length }.sort
report = {
  captured_at: Time.now.utc.iso8601,
  command: "direnv exec . bundle exec ruby script/explain_regexp_filters.rb",
  ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s, faker: Faker::VERSION,
  fixture_rows: rows.length, seed: 314159, native_term: "mithril", expected_native_candidates: 60,
  name_codepoints: { min: lengths.first, median: lengths.fetch(lengths.length / 2), max: lengths.last },
  examples: [0, 30, 50, 60, 180].map { |index| rows.fetch(index).slice(:id, :name) },
  method: "One EXPLAIN ANALYZE BUFFERS per case after count and result-ID checks. No forced planner settings, DDL, or statistics refresh. Temporary rows roll back. The marker condition is included in every case; these small-fixture observations are not a throughput or production latency benchmark.",
  cases: {},
}

RegexpPlanProduct.with_connection do |connection|
  raise "Wrong database" unless connection.select_value("SELECT current_database()") == "tinkick_test"
  report[:postgres] = connection.select_value("SELECT version()")
  report[:tin] = connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'")
  raise "TIN extension required" unless report[:tin]

  owned_ids = rows.map { |row| row.fetch(:id) }
  raise "Refusing to reuse existing fixture IDs" if RegexpPlanProduct.where(id: owned_ids).exists?
  raise "Refusing to reuse an existing fixture marker" if RegexpPlanProduct.where(description: marker).exists?

  begin
    connection.transaction do
      connection.execute("SET LOCAL statement_timeout = '30s'")
      RegexpPlanProduct.insert_all!(rows)
      base = RegexpPlanProduct.where(description: marker)
      native = base.where("name ==> ?", report[:native_term])
      raise "Unexpected TIN candidate count" unless native.count == report[:expected_native_candidates]
      report[:index] = connection.select_value("SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid = 'index_tinkick_test_products_on_name'::regclass")

      patterns.each do |label, pattern|
        narrowed = label == :native_control || label.to_s.end_with?("_native")
        relation = narrowed ? native : base
        relation = Tinkick::Filter.new(RegexpPlanProduct).apply(relation, name: { regexp: pattern }) if pattern
        expected = rows.select do |row|
          value = row.fetch(:name)
          (!narrowed || value.start_with?("mithril ")) &&
            (!pattern || value.include?("Moria")) &&
            (pattern != advanced || !value.include?("Balrog"))
        end.map { |row| row.fetch(:id) }.sort
        count = relation.count
        raise "Wrong count for #{label}: #{count}, expected #{expected.length}" unless count == expected.length

        statements = []
        callback = ->(_name, _start, _finish, _id, payload) { statements << payload.slice(:sql, :binds) }
        ids = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.ids.sort }
        raise "Wrong result IDs for #{label}" unless ids == expected
        statement = statements.find { |entry| entry.fetch(:sql).start_with?("SELECT") }
        raise "Search query not captured" unless statement

        sql = statement.fetch(:sql)
        plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}",
          "Tinkick regexp plan", statement.fetch(:binds))
        binds = statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind }
        report[:cases][label] = {
          pattern: pattern, native_narrowing: narrowed, count: count, result_ids: ids,
          sql: sql, binds: binds, plan: JSON.parse(plan),
        }
      end
      raise ActiveRecord::Rollback
    end
  ensure
    report[:remaining_fixture_ids] = RegexpPlanProduct.where(id: owned_ids).count
    report[:remaining_fixture_rows] = RegexpPlanProduct.where(description: marker).count
    unless report[:remaining_fixture_ids].zero? && report[:remaining_fixture_rows].zero?
      raise "Fixture rollback failed"
    end
  end
end

path = File.expand_path("../docs/benchmarks/2026-09-17-regexp-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(report.slice(:fixture_rows, :name_codepoints, :remaining_fixture_ids, :remaining_fixture_rows).merge(
  cases: report[:cases].transform_values do |entry|
    { count: entry[:count], execution_ms: entry[:plan].first.fetch("Execution Time") }
  end,
))
