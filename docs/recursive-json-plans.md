# Recursive JSONB filter plans

The [captured plans](benchmarks/2026-09-17-recursive-json-plans.json) measure
`where("metadata.tags" => "red")` on PostgreSQL 18.6 Neki / TIN 1.0.2, Ruby
4.0.1, and Rails 8.1.3.1. Reproduce them after migrating the test database:

```sh
direnv exec . bundle exec ruby script/explain_recursive_json_filters.rb
```

The [collector](../script/explain_recursive_json_filters.rb) guards
`tinkick_test` and inserts 100 temporary rows: 40 with nested `tags` containing
`red`, 40 with `red` under an unrelated object key, and 20 unrelated values.
A unique marker excludes existing rows. Explicit negative IDs leave sequences
untouched. The transaction rolls back, and zero remaining owned rows are checked.
There is no DDL or `ANALYZE`.

| Plan | Returned rows | Execution time |
| --- | ---: | ---: |
| Planner's normal choice | 40 | 1.474 ms |
| `enable_seqscan = off` eligibility check | 40 | 1.499 ms |

Both plans use the existing metadata GIN index for the bound recursive equality
candidate predicate. The recursive exact-path subplan runs for 80 candidates;
it excludes all 40 values under unrelated keys. The scalar result never requires
loading model records. The artifact contains the exact SQL and complete plans.

The candidate's `.**` accessor needs the default `jsonb_ops` operator class.
`jsonb_path_ops` does not index recursive descent, as documented in
[PostgreSQL JSON indexing](https://www.postgresql.org/docs/18/datatype-json.html#JSON-INDEXING).
Missing, range, and pattern filters do not have this selective equality candidate.
Recursive verification remains per-row work and logs a warning. Use indexed
persisted or generated scalar columns for frequently filtered values when that
fits the application's schema.

These are single small-fixture executions after a count query, with potentially
warm caches and existing table statistics. They prove matching and index
eligibility, not production latency or throughput. The marker filter is part of
the measured SQL; rerun representative application queries with
`EXPLAIN (ANALYZE, BUFFERS)` before drawing performance conclusions.
