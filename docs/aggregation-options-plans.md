# Native aggregation options: measured plans

These plans were captured on PlanetScale PostgreSQL 18.6 / TIN 1.0.2, Ruby
4.0.1 and Rails 8.1.3.1, using the public search API. They are production-TIN
plan evidence, not Lead performance measurements.

Run `direnv exec . bundle exec ruby script/explain_aggregation_options.rb`
against the dedicated `tinkick_test` database. The script inserts 96 temporary
Faker Tolkien rows (seed 271828), isolates queries with a unique lexical token,
and verifies the same 64 matching IDs for every case. The other 32 rows have
unrelated text and large numeric values that must not affect the results.
Null, empty, all-null, duplicate and populated arrays are represented.
Every expected bucket and metric is checked before capturing its bound SQL
with `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. All inserted rows rolled back;
both the ID and marker cleanup checks returned zero.

| Case | Verified result | Execution time |
| --- | --- | --- |
| Native terms | Four regions, 16 documents each | 0.598 ms |
| Exact include/exclude, limit 1 | Moria: 16; another 16 eligible counts omitted by the limit | 0.589 ms |
| Native regex include | Moria and Rivendell: 16 each | 0.587 ms |
| Missing terms | Unknown: 24; four regions: 16 each | 0.599 ms |
| Missing numeric sum | 376, including one fallback per missing document | 0.477 ms |

All cases retain TIN's text search scan over the 64 matching rows. PostgreSQL
pushes the exact and regex term filters into array expansion: 40 values reach
deduplication, then 32 distinct document/value pairs reach grouping. Ordinary
terms group 64 distinct pairs. Missing terms use a left lateral join and group
88 pairs, including the 24 replacement documents. The sum retains numeric
duplicates and aggregates 72 values with a left lateral join.

Terms still group and sort all eligible bucket values before their output limit;
the limit is not a production TIN top-k optimization. Regex evaluation, array
expansion and wide dictionaries can add cost. These single executions use a
small fixture and possibly warm caches; their similar timings do not establish
production latency, throughput, or equal scaling.

The [raw plans](benchmarks/2026-09-17-aggregation-options-plans.json) include SQL,
binds, result buckets, node counts, timings and buffer statistics. Re-run on a
representative application dataset before making capacity decisions.
