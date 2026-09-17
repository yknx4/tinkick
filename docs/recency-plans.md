# Native recency scoring plans

The [recorded plans](benchmarks/2026-09-17-recency-plans.json) compare native
lexical ordering with public `boost_by_recency` searches. PostgreSQL parses the
intervals and evaluates the decay arithmetic; no Elasticsearch duration parser,
custom database function, or optional extension is involved.

```sh
direnv exec . bundle exec ruby script/explain_recency.rb
```

The collector checks `current_database() = 'tinkick_test'` and the TIN extension.
It inserts 96 deterministic Faker Tolkien records into the existing
`tinkick_test_cursor_values` table inside a transaction. Of these, 64 contain
the searched material and 32 describe unrelated material. A unique lexical
marker isolates the searches; a UUID column value and negative IDs identify
the owned rows for cleanup. No schema change, statistics refresh, or planner
setting is required. The transaction rolls back, and both cleanup counts are
verified as zero.

The old, repeated-term Beren record wins native relevance. The short Holfast
Gardner record is only 500 microseconds before the fixed origin and wins after
recency scoring. Another record is 1500 microseconds before the origin; other
matches have older dates. The collector checks the exact 64 matching IDs,
total counts, expected winners, and expected decay scores before recording
each five-result page's `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.

Captured with Ruby 4.0.1, ActiveRecord 8.1.3.1, PostgreSQL 18.6 on Neki, and
TIN 1.0.2:

| Case | Matching rows | First result | Search execution time |
| --- | ---: | --- | ---: |
| Native lexical relevance | 64 | Old Beren record | 0.757 ms |
| Gaussian recency, `scale: "7d"` | 64 | Recent Holfast Gardner record | 0.942 ms |
| Gaussian recency, `scale: "1500 microseconds"` | 64 | Recent Holfast Gardner record | 0.887 ms |

All three plans use the TIN index followed by a top-N sort in this small,
transaction-owned fixture. **The lexical control did not select TIN Top K**,
so these measurements cannot establish that recency added a sort or measure
the cost of losing that optimization. The separate
[search-plan evidence](query-plans.md) includes native Top K plans on the
committed corpus. TIN's optimization depends on query shape and planner choice;
see its [scoring documentation](https://planetscale.com/docs/postgres/search/scoring).

The recency SQL combines native full scoring with PostgreSQL date extraction,
distance arithmetic, and `exp`. Ordering by that expression can prevent native
top-k execution, so the feature logs a cost warning. Check a representative
application plan rather than extrapolating these timings. Existing statistics,
mutable index entries, the synthetic marker, and warm caches affect this run.
It is execution evidence, not a throughput or production latency benchmark.

Each recency case also performs one initial interval-parsing query, retained
separately in the artifact's `interval_parse_sql` field:

```sql
SELECT EXTRACT(EPOCH FROM '7d'::interval) * 1000;
SELECT EXTRACT(EPOCH FROM '1500 microseconds'::interval) * 1000;
```

These are separate queries for the two cases, not part of their search plans.
The execution times above exclude those round trips and other application work.
PostgreSQL supplies the [interval syntax and precision](https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-INTERVAL-INPUT).
The 1500-microsecond scale becomes 1.5 milliseconds; the two recent records keep
their 0.5- and 1.5-millisecond distances. Their Gaussian multipliers are
approximately 0.925875 and 0.5, respectively. The artifact retains full SQL,
bind values, timestamps, scores, matching IDs, and plans for verification.
