# Native PostgreSQL regexp plans

The [captured plans](benchmarks/2026-09-17-regexp-plans.json) exercise PostgreSQL
regex filters alone and combined with TIN search. There is no Lucene parser,
pattern translation, or custom regex execution path.

Reproduce against the configured test database:

```sh
direnv exec . bundle exec ruby script/explain_regexp_filters.rb
```

The collector checks `current_database() = 'tinkick_test'` and the TIN extension,
then inserts 240 deterministic Faker Tolkien records in a transaction. The data
mixes Moria records, Balrog exclusions, unrelated subjects, multiline text, and
long values. Unique negative IDs and a marker isolate these rows. The transaction
rolls back; the artifact verifies zero remaining fixture rows and IDs.

The ordinary filter is `name ~ 'Moria'`. The combined filter adds
`(name ~ 'Balrog') IS NOT TRUE`, using the existing `_and`/`_not` API.

| Case | Returned rows | Execution time |
| --- | ---: | ---: |
| Native `name ==> 'mithril'` control | 60 | 0.239 ms |
| Regexp, all owned rows | 105 | 0.379 ms |
| Regexp and exclusion, all owned rows | 90 | 0.532 ms |
| Regexp with native TIN predicate | 45 | 0.286 ms |
| Regexp and exclusion with native TIN predicate | 30 | 0.398 ms |

Each query verifies its count and exact result IDs against fixture expectations
before `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`. The artifact retains complete SQL,
binds, results, and plans. No optional extension, DDL, statistics refresh, or forced
planner setting is used.

These are observations from one small fixture, with potentially warm caches,
existing table statistics, and an isolation-marker predicate. They demonstrate
native execution, not production latency. Regex filters still warn about scanning
candidate values; use selective TIN/SQL conditions and inspect application plans.
An appropriate optional `pg_trgm` index may help selective patterns.
