# Raw regexp filter plans

The [captured plans](benchmarks/2026-09-17-regexp-plans.json) compare the ordinary
PostgreSQL regexp path and the Unicode automaton fallback used for Lucene
intersection/complement. They were captured at `2026-09-17T14:09:21Z` on
PostgreSQL 18.6 Neki / TIN 1.0.2, Ruby 4.0.1, Rails 8.1.3.1, and Faker 3.8.0.
Reproduce them after migrating the test database:

```sh
direnv exec . bundle exec ruby script/explain_regexp_filters.rb
```

The [collector](../script/explain_regexp_filters.rb) guards `tinkick_test` and
inserts 240 temporary Tolkien archive-style names, including unrelated topics,
Balrog accounts, Unicode, and longer passages with newlines. Names range from
51 to 1,795 codepoints, with a median of 65. Sixty names contain the native TIN
search term `mithril`. A unique description marker excludes existing rows;
explicit negative IDs leave sequences untouched. The transaction rolls back,
and the artifact records zero remaining owned IDs and marker rows. No DDL,
statistics `ANALYZE`, or forced planner settings are used.

The ordinary pattern is `.*Moria.*`. The advanced pattern is
`.*Moria.*&~(.*Balrog.*)`: it additionally excludes values containing `Balrog`.
These are different predicates, not an equivalent-predicate speed comparison.
Parentheses matter: Lucene complement applies to the following expression, so
the complete exclusion pattern must be grouped. See the pinned
[Lucene regexp parser](https://github.com/apache/lucene/blob/releases/lucene/9.12.2/lucene/core/src/java/org/apache/lucene/util/automaton/RegExp.java).

| Case | Returned rows | Execution time |
| --- | ---: | ---: |
| Native `name ==> 'mithril'` control | 60 | 0.229 ms |
| Ordinary regexp, all owned rows | 105 | 0.475 ms |
| Intersection/complement, all owned rows | 90 | 1,699.612 ms |
| Ordinary regexp with native TIN predicate | 45 | 0.312 ms |
| Intersection/complement with native TIN predicate | 30 | 240.654 ms |

The native control uses a TIN `Text Search Scan` beneath a `TID Materializer`.
Adding the ordinary regexp retains that shape: TIN supplies 60 candidates,
and the materializer filters out 15. Without the native predicate, the ordinary
regexp uses a sequential scan.

The broad intersection/complement query also uses a sequential scan. Its
recursive verification subplan runs 240 times, once per owned value, and its
recursive step runs 33,841 times across those values. The automaton graph is
materialized once. With the native predicate, the planner chooses a TIN bitmap
index scan supplying 60 candidates to a bitmap heap scan; recursive verification
runs 60 times, and its recursive step runs 6,676 times. This demonstrates native
candidate narrowing before exact automaton verification on this query shape.
TIN's documented [SQL shapes](https://planetscale.com/docs/postgres/search/reference/sql-shapes)
allow its matching predicate to be combined with ordinary SQL filters.

The fallback has substantial per-value work in this capture, especially for long
strings. Use selective search and filter conditions where appropriate, and
inspect application plans before applying advanced patterns to a broad result
set. Candidate lengths also differ between the broad and narrowed queries, so
the timings do not establish a fixed per-row cost or a universal speedup.

Each case verifies its count and exact result IDs against independently computed
fixture expectations before one `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` call.
The artifact retains the exact SQL, bound values, IDs, counts, and complete plans.
Caches may already be warm; the table retains its existing statistics, and the
unique marker condition is part of every measured query. These small-fixture
observations demonstrate behavior and plan structure, not production latency or
throughput.
