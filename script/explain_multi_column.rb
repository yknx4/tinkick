# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "../test/dummy/config/environment"
require "json"

# Read-only: run the relevance and query tests first to load their fixture tables.
connection = SearchDocument.connection
raise "Expected tinkick_test" unless connection.select_value("SELECT current_database()") == "tinkick_test"
raise "Run test/relevance_test.rb first" unless SearchDocument.count == 268

cases = []
{
  document_or: ["tinkick_test_documents", "title ==> '(Moria AND Balrog)^1.5' OR body ==> 'Moria AND Balrog'"],
  document_and: ["tinkick_test_documents", "title ==> 'Moria^1.5' AND body ==> 'Balrog'"],
  dense_product_or: ["tinkick_test_products", "name ==> 'apple OR ripe' OR description ==> 'apple OR ripe'"],
}.each do |name, (table, predicate)|
  expected = connection.select_values("SELECT id FROM #{table} WHERE #{predicate} ORDER BY id")
  %w[score full_score].each do |function|
    sql = "SELECT id, tin.#{function}(ctid) AS score FROM #{table} WHERE #{predicate} ORDER BY score DESC LIMIT 10"
    cases << { name: name, scoring: function, sql: sql, matching_ids: expected,
              results: connection.select_all(sql).to_a,
              explain: connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}") }
  end
end

page = SearchDocument.tinkick_search("Moria Balrog", fields: ["title^1.5", :body], misspellings: false, limit: 10)
statements = []
callback = ->(*args) { statements << args.last if args.last[:name] == "SearchDocument Load" }
ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { page.to_a }
statement = statements.find { |entry| entry[:sql].include?("_tinkick_score") }
raise "Missing generated query" unless statement

cases << { name: :tinkick_weighted_columns, sql: statement.fetch(:sql),
          binds: statement.fetch(:binds).map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind },
          results: page.with_score.map { |record, score| { id: record.id, score: score } },
          explain: connection.select_rows("EXPLAIN (ANALYZE, BUFFERS) #{statement.fetch(:sql)}",
            "Multi-column explain", statement.fetch(:binds)).flatten }

report = { captured_at: Time.now.utc.iso8601, database: "tinkick_test", documents: SearchDocument.count,
          postgres: connection.select_value("SHOW server_version"),
          tin: connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'tin'"),
          command: "direnv exec . bundle exec ruby script/explain_multi_column.rb",
          method: "Read-only queries over existing fixtures. One warm EXPLAIN ANALYZE BUFFERS per shape; small-corpus observations, not a production benchmark. matching_ids comes from the same unscored predicate.",
          cases: cases }
path = File.expand_path("../docs/benchmarks/2026-09-17-multi-column-plans.json", __dir__)
File.write(path, JSON.pretty_generate(report) + "\n")
puts JSON.generate(cases.map { |entry| entry.slice(:name, :scoring, :matching_ids, :results) })
