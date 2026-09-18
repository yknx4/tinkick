# Aggregation reference

[Back to the guide](../../README.md)

- [Aggregations and facets](#aggregations-and-facets)

## Aggregations and facets

`aggs`, `aggregations`, `smart_aggs`, and fluent `.aggs` are available. Aggregations
use all matching rows before pagination; they do not instantiate the matching
models. Results are cached on that search relation.

```ruby
results = Product.search("coffee", limit: 20, aggs: [:category])
results.aggs["category"]["buckets"]
# [{"key" => "drinks", "doc_count" => 32}, ...]

Product.search("coffee").aggs(:category).aggs(
  average_price: {avg: {field: :price}},
  price: {ranges: [{to: 10}, {from: 10, to: 25}, {from: 25}]}
).aggs
```

| Feature | Available behavior |
| --- | --- |
| Terms | `field`, `missing`, `include`/`exclude`, `limit` (default 1,000), `min_doc_count` (default 1), and `_key`/`_count` ordering |
| Numeric/date ranges | Inclusive `from`, exclusive `to`, overlapping and empty buckets, optional `key`, and `keyed: true` |
| Numeric histograms | `interval`, `offset`, `min_doc_count` (default 0), `_key`/`_count` ordering, and keyed output |
| Metrics | `avg`, `min`, `max`, `sum`, and exact `cardinality` |
| Per-aggregation filters | `where` limits that aggregation without changing the record results |
| Smart facets | Enabled by default; a facet ignores its own top-level `where` field while retaining other filters |

```ruby
Product.search("coffee", where: {category: "drinks", in_stock: true},
  aggs: {category: {limit: 20, order: {_key: :asc}}})
# Records remain drinks; category buckets include other in-stock categories.

Product.search("coffee", where: {category: "drinks"},
  aggs: [:category], smart_aggs: false)
# Category buckets ignore the global where; record results remain drinks.
```

The fluent `.smart_aggs(false)` modifier is equivalent. Disabled smart facets
keep the lexical query, exclusions, model scopes and per-aggregation `where`,
but ignore the query's global `where` when calculating buckets. Smart facet removal only
examines top-level filter keys, matching Searchkick's behavior. If a facet has its
own `where` and other global filters remain, Searchkick's merge rule applies:
global filters are merged with the facet's filters, and the latter win duplicate
keys. Authorization belongs in a model/database scope that facet selection cannot
remove; do not use a removable facet filter as the only tenant boundary.

`.aggs` returns flattened buckets/metrics; `.aggregations` retains Searchkick's
filtered aggregation envelope and `doc_count`. Both return `nil` when no
aggregations were requested. Array terms count a document once per distinct
value; numeric metrics use every non-null array value. Numeric ranges count each
matching document once per bucket. Null values do not create buckets.

Terms, metrics, numeric/date ranges, and histograms accept `missing:` defaults:

```ruby
Product.search("coffee", aggs: {
  category: {missing: "Uncategorized"},
  average_price: {avg: {field: :price, missing: 0}},
  price_ranges: {field: :price, ranges: [{to: 10}, {from: 10}], missing: 0},
  price_buckets: {histogram: {field: :price, interval: 10, missing: 0}}
})
```

Put the fallback beside `field` for terms/ranges and inside the histogram or
metric hash for `avg`/`min`/`max`/`sum`/`cardinality`. Native SQL `COALESCE` replaces null
values. An empty or all-null array contributes one fallback per document;
a populated array uses its non-null values without adding the fallback.
Empty strings remain values, and a fallback equal to an existing value shares
its bucket. The fallback also applies to the zero-count dictionary and is
subject to `include`/`exclude`. `missing: nil` leaves normal behavior unchanged.
PostgreSQL casts the fallback to the column type; incompatible values raise a
database error. The physical column must exist. Matching rows and filtered
aggregation `doc_count` do not change. Numeric ranges/histograms count a document
once per bucket, including duplicate array values and fallback collisions.
For date ranges, put `missing` beside `date_ranges`; for date histograms, put it
inside `date_histogram`. Timestamp replacements accept Date/Time, ISO8601, or
epoch milliseconds and use the aggregation time zone for inputs without an
explicit offset. DATE columns preserve the supplied calendar date; numeric
epoch replacements use the UTC calendar date. Time zones still control bucket
boundaries. Elasticsearch date math remains unsupported.

`min_doc_count: 0` reads the model's scoped dictionary so unmatched values can
produce zero-count buckets. It logs a warning because broad dictionaries cost
more. Array aggregation and exact `COUNT(DISTINCT)` cardinality also warn about
workload-dependent cost. Aggregations group and sort in PostgreSQL; terms also
apply their bucket limit there. They do not group Ruby model records.
The [captured aggregation plans](../../docs/aggregation-options-plans.md) verify
native filtering and missing-value results on a varied Faker Tolkien corpus
and show the array expansion, grouping, and sorting work.

Use `include` and `exclude` to filter bucket values without changing matching
records. Exact arrays use bound SQL comparisons; exclusion takes precedence.
For array columns, selecting one value keeps that bucket without counting other
values from the same row. Filters also apply to zero-count dictionary buckets,
before ordering and the bucket limit; `sum_other_doc_count` counts only eligible
buckets omitted by that limit.

```ruby
Product.search("coffee", aggs: {
  category: {include: ["drinks", "equipment"], exclude: ["equipment"]},
  brands: {field: :brand, include: "(?i)^acme", exclude: "discontinued$"}
})
```

String patterns use PostgreSQL `~`/`!~` unchanged, including its substring
matching and embedded flags. Use `^`/`$` for anchored matches. Regex filtering
warns about scanning term values; prefer exact arrays when possible. Ruby
`Regexp` objects and Elasticsearch partition hashes raise
`Tinkick::NotImplementedError` with native alternatives. Empty include arrays
select no buckets; empty exclude arrays remove none. These controls apply only
to terms aggregations.

Numeric histograms use an additive portable API. Searchkick exposes this shape
through its raw `body_options` DSL; Tinkick accepts it inside `aggs:`:

```ruby
Product.search("coffee", aggs: {
  prices: {histogram: {field: :price, interval: 10, min_doc_count: 1}}
})
```

Put histogram settings inside `histogram:`; only per-aggregation `where:` goes
alongside it. Bucket keys follow `floor((value - offset) / interval) * interval + offset`.
Array values count each record once per bucket. The default `min_doc_count: 0`
fills gaps between matching buckets in SQL and logs a warning: small intervals
over wide ranges can return many empty buckets. Use `min_doc_count: 1` when gaps
are unnecessary. `extended_bounds: {min: 0, max: 100}` expands that empty-bucket
range without excluding occupied buckets. `hard_bounds: {min: 0, max: 100}`
filters occupied bucket ordinals with inclusive endpoints before applying
`offset`. Each bound may omit an endpoint; extended endpoints must fit within
the supplied hard endpoints. Both extended endpoints can produce an empty-data
histogram. Format returned numeric values in the application, for example with
Rails `number_with_precision`. Elasticsearch's Java numeric format patterns are
outside this gem's native SQL API.

With offsets, rounded extended buckets can fall outside the numeric hard bounds,
matching Elasticsearch's empty-bucket behavior. For example, interval 10,
offset 5, hard min 0, and extended min 0 can emit an empty bucket at -5. Use
explicit input filters when a value range must restrict matching records.

Date ranges accept `Date`, `Time`, ISO8601 strings, or epoch-millisecond bounds.
`time_zone` accepts an IANA name, a fixed ISO offset, or numeric hours (truncated
toward zero); UTC is the default. Explicit input offsets and epoch values preserve
their instant. Numbers and integer strings always mean epoch milliseconds.

```ruby
zone = Time.find_zone!("America/Vancouver")
Product.search("coffee", aggs: {
  created_at: {
    date_ranges: [{from: zone.now.beginning_of_day - 7.days, to: zone.now.beginning_of_day}],
    time_zone: "America/Vancouver"
  }
})
```

Output labels default to ISO8601 with milliseconds. `format: "epoch_millis"`
returns epoch-millisecond labels; `"strict_date_optional_time"` explicitly selects
the default. Elasticsearch date math (`now-7d/d`, `date||/M`), Java date patterns,
and format alternatives raise `Tinkick::NotImplementedError`. Compute boundaries
with Ruby/Rails and format returned dates in the application. Use PostgreSQL
`to_char` in an explicit SQL query when database-side custom labels are required.

Calendar date histograms count matching records independently of result
pagination and fill intervening empty buckets by default:

```ruby
Product.search("coffee", aggs: {
  months: {date_histogram: {field: :created_at, calendar_interval: :month}}
})
```

Supported calendar units are second, minute, hour, day, week (Monday start),
month, quarter, and year, including `1s`, `1m`, `1h`, `1d`, `1w`, `1M`, `1q`, and
`1y` aliases. Buckets contain an epoch-millisecond `key`, ISO8601 `key_as_string`,
and `doc_count`. For fixed durations, use `fixed_interval: "90m"` instead of
`calendar_interval`. Fixed intervals support positive integer `ms`, `s`, `m`,
`h`, and `d` quantities, with buckets anchored at the Unix epoch; `250ms` works
on both sides of 1970. `micros` and `nanos` durations truncate to whole
milliseconds and must be at least one millisecond. Fractional quantities and
calendar units such as months are invalid fixed durations.

Date histograms default to UTC and accept fixed `time_zone` offsets, such as
`"+01:30"`, `"-05:00"`, or numeric `-5`, and IANA names such as
`"America/New_York"`. Fixed offsets are limited to ±18 hours. Calendar buckets
use PostgreSQL's three-argument `date_trunc`; fixed buckets use `date_bin` with
local midnight on 1970-01-01 as the origin. Fixed intervals always measure elapsed
time, including across daylight-saving transitions. Calendar days can span 23 or
25 hours. Historical offsets and ambiguous or missing local times follow native
PostgreSQL rules; Tinkick does not reconstruct Elasticsearch timezone behavior.
The numeric `key` remains UTC epoch milliseconds and `key_as_string` displays the
local boundary. Offset labels include hours and minutes.

PostgreSQL groups matching records and fills empty buckets with `generate_series`
without loading models. Populated buckets are retained even when a timezone
transition changes the calendar series. Explicit bounds add one query to round
four scalar endpoints. See PostgreSQL's [date/time functions](https://www.postgresql.org/docs/18/functions-datetime.html)
and [series generators](https://www.postgresql.org/docs/18/functions-srf.html).

Put `min_doc_count`, `order`, `keyed`, and `format` inside `date_histogram:`;
only per-aggregation `where:` belongs alongside it. Set `min_doc_count: 1` to
avoid generating empty buckets. The default logs a warning because small
intervals over wide date ranges can produce many buckets. `format: "epoch_millis"`
changes labels and keyed bucket names while numeric keys remain UTC milliseconds.

Use `offset: "+6h"` inside `date_histogram:` to shift bucket boundaries. Signed
fixed durations or numeric milliseconds are accepted; numeric fractions truncate
toward zero. Rounding subtracts this elapsed offset before applying the time zone
and adds it back to the UTC boundary afterward. Consequently, `+6h` daily buckets
in New York can start at 07:00 on the spring transition day. This is elapsed-time
offset behavior, not a promise of the same local wall-clock boundary every day.
Large offsets also retain calendar-month spacing across February.

Use `extended_bounds` to include dates outside the matching records:

```ruby
Product.search("coffee", aggs: {
  months: {date_histogram: {
    field: :created_at, calendar_interval: :month,
    extended_bounds: {min: "2026-01-01", max: "2026-12-31"}
  }}
})
```

Bounds expand the output without filtering matching records. Either endpoint may
be omitted; an empty result set needs both to create buckets. Empty buckets are
generated only with `min_doc_count: 0`. Bounds accept Date/Time values, ISO8601
strings and integral epoch milliseconds. Timezone-free ISO strings use
`time_zone`; integer strings mean epoch milliseconds. Bounds round on the
configured time grid before the aggregation offset is added. Wide bounds with
small intervals can generate many buckets and retain the empty-bucket warning.

Use `hard_bounds: {min: "2026-01-01", max: "2026-07-01"}` to restrict which
date buckets collect matches. The rounded minimum is inclusive and maximum is
exclusive; this example admits January through June monthly buckets. Endpoints
use the same parsing as extended bounds and round without the aggregation
offset. The restriction then tests the final shifted UTC bucket key. Either
endpoint may be omitted, and hard bounds alone do not create empty buckets.
Date arrays count each record once per eligible bucket; null and empty arrays
contribute no bucket counts.

When combining bounds, extended endpoints must fit within the rounded hard
endpoints. Extended bounds describe the empty output grid; hard bounds restrict
which populated buckets collect records. Explicit `where:` filters are available
when the input timestamps themselves must fall within a range.

Elasticsearch nested/reverse-nested and pipeline aggregation DSL, Java numeric
format patterns, and Painless scripts are outside this gem's native SQL API.
Searchkick exposes general subaggregations through `body_options`; Tinkick does
not translate that Elasticsearch request body. Use ActiveRecord `group` and
aggregate queries, explicit SQL subqueries/window functions, or a reviewed
persisted/generated column for those calculations. This is an API boundary,
not a claim that PostgreSQL cannot perform grouped or nested calculations.
Scalar JSONB aggregation paths remain follow-up work. JSONB filtering and scalar
text search are available independently.
Check representative plans against TIN's
[SQL shape guidance](https://planetscale.com/docs/postgres/search/reference/sql-shapes).
