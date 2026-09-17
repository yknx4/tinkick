# frozen_string_literal: true

require_relative "../lib/tinkick"
require "faker"
require "json"
require "securerandom"
require "time"

# Uses the existing migrated test table. Fixture inserts are rolled back; no
# existing rows, schema, or extensions are changed. No ANALYZE is performed.
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "tinkick_test")

class IanaFixedPlanValue < ActiveRecord::Base
  self.table_name = "tinkick_test_cursor_values"
  tinkick searchable: [:name]
end

report = {
  captured_at: Time.now.utc.iso8601, ruby: RUBY_VERSION, rails: ActiveRecord.version.to_s,
  command: "direnv exec . bundle exec ruby script/explain_iana_fixed_histograms.rb",
  method: "One EXPLAIN ANALYZE BUFFERS immediately after each public aggregation. A rollback-only fixture inserts 1,000 matching Tolkien observations and 256 unrelated itineraries, uniformly distributed through 2026. Every query filters a unique per-run UUID code to exclude preexisting rows. Explicit negative fixture IDs preserve the table sequence. No ANALYZE or schema changes are performed; estimates use existing table statistics. Warm caches are possible. Client aggregation time includes round trips and formatting, while EXPLAIN execution time excludes them. This is execution-shape evidence, not a throughput or production-latency benchmark.",
  cases: [],
}
run_code = SecureRandom.uuid
id_base = -(run_code.delete("-").to_i(16) % (2**60) + 1)
ActiveRecord::Base.with_connection do |connection|
  raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"
  raise "Run test/integration/iana_fixed_histograms_test.rb to prepare the migrated table" unless connection.data_source_exists?(IanaFixedPlanValue.table_name)

  report[:postgres] = connection.select_value("SELECT version()")
  report[:tin] = connection.select_value("SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'tin'")
  raise "tinkick_test requires TIN" unless report[:tin]
  report[:existing_dataset] = connection.select_one("SELECT COUNT(*) AS rows, MIN(recorded_at) AS earliest, MAX(recorded_at) AS latest FROM tinkick_test_cursor_values")
  report[:fixture] = { seed: 314_159, faker: Faker::VERSION, code: run_code, matching_rows: 1_000, unrelated_rows: 256,
                       date_distribution: "Uniform UTC instants from 2026-01-01T00:00:00Z to 2026-12-31T23:59:59Z; matching and unrelated rows each span the full year." }
  random = Faker::Config.random
  begin
    Faker::Config.random = Random.new(314_159)
    connection.transaction do
      connection.execute("SET LOCAL statement_timeout = '30s'")
      rows = [1_000, 256].each_with_index.flat_map do |count, category|
        count.times.map do |index|
          instant = Time.utc(2026, 1, 1) + (365 * 86_400 - 1) * index / (count - 1)
          description = "#{Faker::Fantasy::Tolkien.character} near #{Faker::Fantasy::Tolkien.location}"
          { id: id_base - index - category * 1_000, name: "#{category.zero? ? "Mithril observation" : "Travel itinerary"} #{description}", code: run_code,
            recorded_on: instant.to_date, recorded_at: instant, price: index }
        end
      end
      IanaFixedPlanValue.insert_all!(rows)
      raise "Fixture count mismatch" unless IanaFixedPlanValue.where(code: run_code).count == 1_256

      cases = [
        [:iana_sparse_year, "90m", "America/New_York", 1, {}],
        [:iana_dense_year, "90m", "America/New_York", 0, {}],
        [:iana_dense_fold_window, "90m", "America/New_York", 0, { recorded_at: { gte: Time.utc(2026, 10, 31), lt: Time.utc(2026, 11, 3) } }],
        [:iana_long_interval, "400d", "America/New_York", 1, {}],
        [:fixed_offset_dense_year, "90m", "-05:00", 0, {}],
      ]
      cases.each do |name, interval, zone, minimum, date_filter|
        conditions = date_filter.merge(code: run_code)
        matched = Tinkick::Filter.new(IanaFixedPlanValue).apply(IanaFixedPlanValue.all, conditions)
          .where(Arel.sql("name ==> ?", "observation"))
        inventory = matched.pluck(Arel.sql("COUNT(*), MIN(recorded_at), MAX(recorded_at)")).fetch(0)
        raise "#{name} cannot measure an empty match set" unless inventory.fetch(0).positive?
        raise "Fixture should have exactly 1,000 matching rows" if date_filter.empty? && inventory.fetch(0) != 1_000

        options = { field: :recorded_at, fixed_interval: interval, time_zone: zone, min_doc_count: minimum }
        query = IanaFixedPlanValue.tinkick_search("observation", misspellings: false, where: conditions,
          smart_aggs: false, aggs: { events: { date_histogram: options } })
        statements = []
        listener = ->(*arguments) { statements << arguments.last.slice(:sql, :binds) }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { query.aggs }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        buckets = result.fetch("events").fetch("buckets")
        raise "#{name} dropped matching documents" unless buckets.sum { |bucket| bucket.fetch("doc_count") } == inventory.fetch(0)

        statement = statements.find { |entry| entry.fetch(:sql).include?(" AS _tinkick_key") }
        raise "Missing aggregation SQL for #{name}" unless statement

        plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
          "Tinkick IANA Fixed Explain", statement.fetch(:binds))
        report[:cases] << {
          name: name, term: "observation", options: options, where: conditions, smart_aggs: false,
          matching_rows: inventory.fetch(0), earliest: inventory.fetch(1), latest: inventory.fetch(2),
          bucket_count: buckets.length, populated_buckets: buckets.count { |bucket| bucket.fetch("doc_count").positive? },
          first_buckets: buckets.first(3), last_buckets: buckets.last(3), client_elapsed_ms: elapsed * 1_000,
          sql: statement.fetch(:sql),
          binds: statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind },
          explain: JSON.parse(plan),
        }
      end
      raise ActiveRecord::Rollback
    end
  ensure
    Faker::Config.random = random
    remaining = IanaFixedPlanValue.where(code: run_code).count
    raise "Fixture rollback failed: #{remaining} owned rows remain" unless remaining.zero?

    report[:cleanup] = { rolled_back: true, remaining_owned_rows: remaining }
  end
end

path = File.expand_path("../docs/benchmarks/2026-09-17-iana-fixed-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(path: path, existing_dataset: report[:existing_dataset], cleanup: report[:cleanup],
  cases: report[:cases].map { |entry| { name: entry[:name], matching_rows: entry[:matching_rows], bucket_count: entry[:bucket_count], execution_ms: entry[:explain].first["Execution Time"] } })
