# IANA fixed-interval histogram plans

The [captured plans](benchmarks/2026-09-17-iana-fixed-plans.json) establish the
execution shape of public `date_histogram` aggregations on PostgreSQL 18.6 Neki
with TIN 1.0.2, Ruby 4.0.1, and Rails 8.1.3.1. They were collected on
2026-09-17. Reproduce them with:

```sh
direnv exec . bundle exec ruby script/explain_iana_fixed_histograms.rb
```

The [collector](../script/explain_iana_fixed_histograms.rb) refuses any database
other than `tinkick_test` and requires the existing migrated cursor-values
table. Its initial inventory found **zero persistent timestamp rows**. It
therefore measures a documented fixture: 1,000 matching Tolkien observations
and 256 unrelated itineraries, each distributed uniformly across 2026. Faker
3.8.0 uses seed 314159. Every query filters a unique fixture UUID in `code`;
explicit negative primary keys preserve the table's sequence. The fixture is
inserted in a transaction and rolled back, with zero remaining owned rows
verified afterward. No schema changes or `ANALYZE` are performed.

| Case | Matched rows | Returned buckets | Daily offset samples | Server execution |
| --- | ---: | ---: | ---: | ---: |
| New York, 90m, `min_doc_count: 1`, full year | 1,000 | 1,000 | 370 | 8.628 ms |
| New York, 90m, `min_doc_count: 0`, full year | 1,000 | 5,842 | 370 | 24.062 ms |
| New York, 90m, Oct 31–Nov 3 filter | 8 | 42 | 7 | 1.859 ms |
| New York, 400d, `min_doc_count: 1`, full year | 1,000 | 2 | 769 | 7.074 ms |
| Fixed offset −05:00, 90m, full year | 1,000 | 5,841 | None | 9.391 ms |

Each is one `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` immediately after the same
public aggregation; caches may be warm. These measurements do not establish
relative speed, concurrency behavior, throughput, or production latency. The
artifact separately records client elapsed time, which includes round trips
and Ruby bucket formatting. Every case verifies nonzero matches and that bucket
counts account for all matched documents.

All five plans use one TIN `Text Search Scan`, followed by a `TID Materializer`.
The date filter removes 992 of the 1,000 text matches at the materializer: it
reduces the aggregation and timezone-discovery range, but this plan still reads
all text matches first. The IANA plans materialize matching inputs once and
reuse them for range discovery and SQL grouping. No model records are loaded
to calculate counts. Empty buckets add SQL series generation and a join with
the populated counts. The fixed-offset control avoids transition discovery;
its bucket grid differs because New York changes UTC offset.

The annual IANA range discovers two offset changes; the 400-day lookback
discovers four. Sparse aggregation still performs that discovery, so two
returned buckets do not imply only two units of work. All captured plans show
zero shared reads and zero temporary-block reads/writes. Estimates are weak:
the dense annual root estimates 11,394,266 rows but returns 5,842, and the narrow
case retains the same estimate but returns 42. The transient fixture uses
existing table statistics; these plans do not establish behavior on a large,
analyzed application table. Selective date filters and `min_doc_count: 1` reduce
real work here, consistent with the gem's warnings about wide ranges and dense
empty buckets.

The rounding strategy follows Elasticsearch's
[fixed-interval gap and overlap rules](https://github.com/elastic/elasticsearch/blob/v8.19.0/server/src/main/java/org/elasticsearch/common/Rounding.java#L1184-L1376),
while PostgreSQL supplies the actual timezone offsets. Daily discovery assumes
at most one offset change per UTC day. An offline audit of 598 installed
`/usr/share/zoneinfo` identifiers through TZInfo 2.0.6, from 1850-01-01 inclusive
to 2050-01-01 exclusive, found a minimum **601,200 seconds** between consecutive
offset-changing transitions. Label-only transitions with unchanged total
offset are excluded. Observed offsets ranged from −43,200 to +54,822 seconds,
a span of 98,022 seconds. This supports the daily search and one-interval-plus-
two-days lookback for that data; it is a bounded audit, not a guarantee about
every PostgreSQL timezone database version or future rule change.

Historical timezone versions can disagree. The
[public regression tests](../test/integration/iana_fixed_histograms_test.rb)
pin PostgreSQL's Amsterdam result for a one-minute interval at
`1937-06-30T22:40:30Z`: its key is `22:40:28Z`, rendered as
`1937-07-01T00:00:28.000+01:20`. The installed JVM's Elasticsearch oracle uses
`22:40:00Z` for that input. The gem preserves PostgreSQL's history instead of
emulating a different timezone database. The five plans above cover modern
New York scalar timestamps; historical transitions, date arrays, and bounds
are correctness-test coverage, not additional measured workloads here.
