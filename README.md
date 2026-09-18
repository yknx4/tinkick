# Tinkick

Searchkick-style search for Ruby and Rails, backed by
[PlanetScale TIN](https://planetscale.com/docs/postgres/search). Your model's
PostgreSQL table is the datasource. PostgreSQL maintains the search indexes when
rows change; there is no second document store to synchronize.

**Status: alpha.** Core search includes word, phrase, partial and exact matching,
native typo tolerance, SQL/JSONB filters, relevance boosts, highlighting, facets,
model/raw-row results, and page, keyset and countless pagination. The priority is
practical Rails search with native TIN performance, not complete Searchkick API
parity. This guide covers the feature surface of
the [Searchkick 6.1.2 reference README](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/README.md),
including features that still need native integration or a different application design.

Implementation stays within TIN, PostgreSQL, and available extensions. Backend
differences are part of the API contract: unsupported explicit controls raise
clear errors instead of invoking custom Lucene or Elasticsearch emulation.

Throughout this guide:

- **Available** means implemented in Tinkick. Examples without another label use
  the current API.
- **Not implemented** means the Searchkick option or return interface is missing
  from Tinkick. It does not mean PostgreSQL or TIN cannot do it.
- **Excluded** means an Elasticsearch/OpenSearch transport, document import, or
  index lifecycle API has no direct role in this backend.
- **Native difference** identifies a documented or tested engine behavior.
- **Recipe** means application-owned SQL or ActiveRecord code, with its own
  return shape and behavior. A recipe is not a compatible Tinkick API.

## Contents

- [Requirements and installation](docs/reference/installation.md#requirements-and-installation)
- [Getting started](docs/reference/installation.md#getting-started)
- [Migrating alongside Searchkick](docs/reference/installation.md#migrating-alongside-searchkick)
- [Datasource and migrations](docs/reference/installation.md#datasource-and-migrations)
- [Querying](docs/reference/querying.md#querying)
- [Results and metadata](docs/reference/results.md#results-and-metadata)
- [Filtering](docs/reference/filtering.md#filtering)
- [Matching and analysis](docs/reference/matching.md#matching-and-analysis)
- [Boosting, conversions, and personalization](#boosting-conversions-and-personalization)
- [Autocomplete and suggestions](docs/reference/matching.md#autocomplete-and-suggestions)
- [Aggregations and facets](#aggregations-and-facets)
- [Highlighting](docs/reference/results.md#highlighting)
- [Similar items, geospatial, and vector search](#similar-items-geospatial-and-vector-search)
- [Pagination and large result sets](docs/reference/results.md#pagination-and-large-result-sets)
- [Models, scopes, and tenancy](docs/reference/querying.md#models-scopes-and-tenancy)
- [Indexing and synchronization](#indexing-and-synchronization)
- [Advanced SQL and debugging](#advanced-sql-and-debugging)
- [Performance and consistency](#performance-and-consistency)
- [Deployment and operations](#deployment-and-operations)
- [Testing](#testing)
- [Reference and unsupported options](#reference-and-unsupported-options)
- [Development, upgrades, and contributing](#development-upgrades-and-contributing)
- [License](#license)

## Requirements and installation

See the [requirements and installation reference](docs/reference/installation.md#requirements-and-installation).

## Getting started

See the [getting started reference](docs/reference/installation.md#getting-started).

## Migrating alongside Searchkick

See the [migrating alongside searchkick reference](docs/reference/installation.md#migrating-alongside-searchkick).

## Datasource and migrations

See the [datasource and migrations reference](docs/reference/installation.md#datasource-and-migrations).

## Querying

See the [querying reference](docs/reference/querying.md#querying).

## Results and metadata

See the [results and metadata reference](docs/reference/results.md#results-and-metadata).

## Filtering

See the [filtering reference](docs/reference/filtering.md#filtering).

## Matching and analysis

See the [matching and analysis reference](docs/reference/matching.md#matching-and-analysis).

## Boosting, conversions, and personalization

Native word, phrase, and partial-word fields accept caret weights:

```ruby
Product.search("coffee", fields: ["name^10", :description])
Product.search("coffee", misspellings: false).fields({"name^2.5" => :word_start}, :description)
```

Weights from zero through 10,000 use native TIN boosts. Zero preserves matching
rows while suppressing that field's score. `default_fields` and wildcard selectors
also accept weights. Repeated selectors use the last explicit weight for that
selector and match mode; an unweighted duplicate does not reset it. Per-field
`misspellings: {fields: [...]}` uses names without caret weights.

Explicit `^1` pins terms that TIN might otherwise omit from scoring as too common,
so it can change scores even with a factor of one. Native single-field queries
retain the top-k path; multi-field and SQL-scoring cost warnings still apply.
Scores use TIN's ranking without synthetic exact-versus-fuzzy boosts or forced
primary-key tie order.

Exact and whole-field text modes also accept weights. Factors above 10,000 use
SQL multiplication of native scores. These paths run a matching branch per field,
sum each record's contributions, then sort; they log a performance warning because
native top-k cannot supply the final weighted ordering. SQL exact/text matches
contribute the specified weight (one when omitted); a zero weight keeps the match.
Filters, exclusions, highlights, and column cursors retain their normal behavior.

```ruby
Product.search("coffee", fields: [{"name^20" => :exact}, "description^1"])
Product.search("coffee", fields: ["name^20000", :description])
```

Measure this path with `EXPLAIN (ANALYZE, BUFFERS)` on representative data: a
large-weight query over the 268-document test corpus used a TIN scan followed by
aggregation, a join, and a final sort, without native top-k. That small fixture
plan is evidence of the query shape, not a production latency estimate. The
[native and SQL weight plans](docs/query-plans.md#native-and-sql-field-weights)
include captured SQL/binds and a reproducible collector.

Numeric table columns and numeric PostgreSQL arrays support `boost_by`:

```ruby
Product.search("coffee", boost_by: [:orders_count])
Product.search("coffee", boost_by: {
  orders_count: {factor: 2},
  rating: {modifier: "sqrt", boost_mode: "multiply", missing: 1}
})
Product.search("coffee").boost_by(:orders_count).boost_by(rating: {factor: 0.5})
```

The legacy `boost: :orders_count` keyword and `.boost(:orders_count)` use the
same default numeric formula. Repeated `.boost` calls replace that single field.
When combined with `boost_by`, the alias replaces the same field's default sum
contribution but preserves an explicitly configured `boost_mode: "multiply"`
contribution. `boost: false` or `nil` disables the alias. Prefer `boost_by` for
new code so the factor and modifier are explicit.

The default contribution is `ln(2 + factor * value)`. Default contributions are
summed, then multiply the base relevance score. Fields with
`boost_mode: "multiply"` default to modifier `"none"`; their contributions are
multiplied together and also multiply the base score. Supported modifiers are
`none`, `log`, `log1p`, `log2p`, `ln`, `ln1p`, `ln2p`, `square`, `sqrt`, and
`reciprocal`. The `log` family uses base 10.

Missing values skip their contribution unless `missing:` supplies a replacement;
`missing: 0` is a real replacement. A group with no applicable contributions
leaves the score unchanged. Arrays use their minimum non-NULL value before
applying the factor and modifier; empty/all-NULL arrays are missing. Groups use
PostgreSQL arithmetic and return double-precision scores without an Elasticsearch
Float32 cap. Division by zero and overflow raise native database errors, including
`reciprocal` applied to zero. Negative/NaN function scores also raise an error.

These calculations require only PostgreSQL arithmetic. They log a warning because
numeric ranking can sort all matches instead of using TIN top-k, and arrays inspect
values per matching row. Counts and aggregation membership retain the original
matching scope. Source projection, highlights, countless pagination, and stable
column cursors remain available. Add real numeric columns with Rails migrations
for counters or application-owned scores; Ruby `search_data` values are not stored.

JSONB dotted paths also work without a separate numeric index:

```ruby
Product.search("coffee", boost_by: {"metadata.offers.rating" => {modifier: "sqrt", missing: 1}})
```

An explicitly boosted JSONB path is interpreted as numeric. Numbers and numeric
strings are coerced through PostgreSQL double precision; arrays are flattened
and their minimum numeric value is used. Paths can traverse arrays of objects,
following only the named keys. Missing values, JSON null, empty strings and empty
arrays use the same `missing:` behavior as columns. This follows Elasticsearch's
[numeric coercion](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/coerce.html)
and [array conventions](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/array.html),
without inferring an integer mapping from the first stored value.

Tinkick does not validate JSONB when it is written: malformed, boolean, object or
nonfinite leaf values raise when a matching row is scored. Filtered-out invalid
rows are not scored, and counts do not evaluate the boost. Recursive traversal
adds work per row; persist frequently used ranking values in typed columns when
that improves the measured plan. Updates are visible immediately without reindexing.

Conditional weights support the same SQL field predicates as filtering:

```ruby
Product.search("coffee", boost_where: {in_stock: true})
Product.search("coffee", boost_where: {
  category: [{value: "featured", factor: 5}, {value: "clearance", factor: 0.25}]
})
Product.search("coffee").boost_where(in_stock: true).boost_where(category: {value: "featured", factor: 5})
```

The shorthand weight is 1,000. Explicit factors accept finite nonnegative numbers
or numeric strings; factors between zero and one demote matching records. Signed
zero behaves as zero, and infinite factors are rejected. All
matching conditional weights are summed with the default `boost_by` contributions,
then multiply the native score. Records with no applicable contribution keep
their original score. A zero conditional weight adds no contribution, so zero
alone does not remove a record or zero its score. Repeated fluent calls merge
fields, with the later condition replacing the earlier one for the same field.

Conditions may use NULLs, arrays, ranges, JSONB paths and supported filter
operators. A `{value:, factor:}` descriptor uses `value` as its filter condition.
These predicates change scoring only: matching records, counts and aggregation
membership stay unchanged. They require no additional extension beyond those
needed by the selected filter operators. Conditional scoring logs a warning
because evaluating predicates and sorting matches can replace native TIN top-k;
inspect `EXPLAIN (ANALYZE, BUFFERS)` on representative data. Native single-precision
scores and SQL arithmetic may expose different numbers of decimal digits.

Recency boosts apply a decay function around a chosen origin:

```ruby
Product.search("coffee", boost_by_recency: {created_at: {scale: "7d", decay: 0.5}})
Product.search("coffee").boost_by_recency(
  published_at: {origin: Time.current, scale: "30d", offset: "2d", function: :exp, factor: 3}
)
```

The default function is `gauss`, the origin is the query's current time, and
`decay` defaults to 0.5. `scale` is required. With distance
`d = max(abs(value - origin) - offset, 0)`, the unweighted functions are:

| Function | Contribution |
| --- | --- |
| `gauss` | `decay ** ((d / scale) ** 2)` |
| `exp` | `decay ** (d / scale)` |
| `linear` | `max(0, 1 - (1 - decay) * d / scale)` |

Future and past values decay symmetrically; `offset` creates a full-weight
plateau around the origin. The factor multiplies each contribution, which joins
the same sum group as default numeric boosts and conditional weights. Missing
values contribute the full factor. Date and numeric arrays use the nearest
non-NULL value; empty/all-NULL arrays are missing. Repeated fluent calls merge
fields and replace earlier options for the same field.

Date scales and offsets use [PostgreSQL interval strings](https://www.postgresql.org/docs/18/datatype-datetime.html#DATATYPE-INTERVAL-INPUT),
such as `"7d"`, `"1.5 days"`, `"2 weeks"`, or `"1500 microseconds"`. The scale
must be positive and the offset nonnegative. Bare nonzero numeric date durations
are rejected; include a unit. PostgreSQL `EXTRACT(EPOCH FROM interval)` supplies
the duration, so months use its fixed 30-day conversion rather than calendar
arithmetic. Each distinct interval string is parsed in one SQL query per scoring
compiler and reused across fields. Invalid strings raise a native database error.

Origins accept dates, times, ISO8601 strings and epoch milliseconds, preserving
fractional milliseconds. Compute relative origins in the application, for example
`1.day.ago`; Elasticsearch date math strings raise `Tinkick::NotImplementedError`.
Factors must be finite and nonnegative and have no Float32 cap. Negligible distant
scores become zero to avoid PostgreSQL floating-point exponential underflow.
Numeric columns also accept these functions with explicit numeric `origin` and
`scale`. Recency ranking requires a typed PostgreSQL column. Dotted JSONB paths
raise `Tinkick::InvalidQueryError` with migration guidance: Tinkick does not infer
whether a JSON number or string represents a date or a numeric measurement.

Persist the values needed for ranking in typed columns:

```ruby
class AddProductRecencyFields < ActiveRecord::Migration[8.0]
  def change
    add_column :products, :search_published_at, :datetime, precision: 6
    add_column :products, :search_distance, :decimal
  end
end
```

Backfill these columns using the application's date/numeric interpretation and
keep them updated when the source JSONB changes. Once populated, search with
`boost_by_recency: {search_published_at: {scale: "7d"}}`, or use the numeric
column with an explicit origin and scale. No JSONB type mapping or date parser
is added by the gem.

A stored generated column is also suitable when its expression is immutable.
[PostgreSQL requires immutable generated expressions](https://www.postgresql.org/docs/18/ddl-generated-columns.html).
Direct text-to-timestamp casts do not meet that requirement: PostgreSQL marks
its timestamp input functions as stable, rather than immutable, in the
[native function catalog](https://raw.githubusercontent.com/postgres/postgres/REL_18_STABLE/src/include/catalog/pg_proc.dat).
Use an ordinary maintained timestamp column for JSON timestamp strings instead
of wrapping those casts in a falsely declared immutable function.

Recency scoring needs no optional extension. It logs the additional per-row
calculation and sorting cost; counts and aggregation membership remain unchanged.
`nil`, `false` and `{}` disable the option. A single zero-weight recency function
zeros scores; multiple functions whose applicable weights are all zero retain
the original score, matching the upstream sum-group behavior.
See the [native recency query plans](docs/recency-plans.md) for a reproducible
small-corpus comparison.

`boost_by_distance` and `indices_boost` still require geographic and multi-model
query support.

Recipe: rank a bounded SQL search with application-owned numeric weights:

```ruby
Product.where("name ==> ?", "apple")
  .select("products.*, tin.score(products.ctid) + 0.1 * coalesce(orders_count, 0) AS rank")
  .order(Arel.sql("rank DESC")).limit(20)
```

This is not Searchkick's boost formula and may require sorting all matches.
Choose explicit handling for NULLs, negative values, units, and the magnitude of
the text score. Recency needs a date-based expression; demotion needs a lower
weight; personalized purchase history needs a join or persisted feature column.
Profile the actual plan before using these recipes at scale.

### Conversion ranking

Store query/count pairs in a real JSONB model column. Create it through a Rails
migration, then declare it for conversion scoring:

```ruby
class AddConversionCountsToProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :products, :conversion_counts, :jsonb, default: {}, null: false
  end
end

class Product < ApplicationRecord
  tinkick searchable: [:name], conversions_v2: [:conversion_counts]
end

product.update!(conversion_counts: {"red apple" => 5, "green apple" => 2})
Product.search("red apple") # v2 is enabled when no legacy fields are declared
Product.search("apple", conversions_v2: {term: "red apple", factor: 0.5})
Product.search("apple", conversions_v2: false)
```

Legacy `conversions:` (alias `conversions_v1:`) and `conversions_v2:` model
declarations accept one or multiple column names; the same field cannot belong to
both. Query `conversions:` replaces the legacy selection with a name or array;
`false` or `[]` disables it. Query `conversions_v2:` accepts a name, `true` for all
declared v2 fields, or `{field:, term:, factor:}`. The factor defaults to 1; zero
skips the v2 JSONB work entirely. `conversions_term:` overrides the lookup term for both versions,
with a v2 hash's `term` taking precedence. Overrides use ordinary `to_s` after
nil/false fallback.

When both versions are declared, searches use legacy fields by default. Enabling
v2 does not disable legacy, and disabling legacy does not enable v2. To switch
explicitly, use:

```ruby
Product.search("apple", conversions: false, conversions_v2: true)
Product.search("apple").conversions(false).conversions_v2(field: :conversion_counts, factor: 0.5)
```

Fluent conversion methods take one argument and return a clone. Their bang
variants mutate an unloaded relation; v2 option hashes replace the previous hash.

Tinkick adds selected counts to relevance before other boost multipliers; v2
counts are multiplied by their factor. Conversion scoring changes ranking,
without changing matching rows, counts or aggregation membership. Match-all
`"*"` searches skip it. Column validation happens when scoring is requested.

Keys are literal whole strings: dots are ordinary characters, and no stemming or
accent folding occurs. By default, PostgreSQL `lower` compares keys and sums all
matching case variants. A model declared with `case_sensitive: true` uses exact
key lookup. `stem_conversions: true` raises `Tinkick::NotImplementedError`; persist
normalized keys and supply the corresponding `conversions_term` instead.

Missing keys, SQL NULL and JSON null contribute zero. Matching counts use native
PostgreSQL numeric casts: numeric strings work, malformed values fail, and
negative/nonfinite counts are rejected. Unrelated keys are not cast. Factors
must be finite and nonnegative. Scoring logs its potential sorting cost and
case-insensitive JSONB iteration per row. It needs no
optional extension and does not promise native TIN top-k performance. See the
[conversion contract](docs/conversions-contract.md) and
[reproducible query plans](docs/conversion-plans.md).

### Conversion tracking

`track` and Searchjoy integration are not implemented. Applications own event
storage, count aggregation and column updates; updating conversion counts needs
no search-document reindex.

The gem creates no conversion cron jobs, queues, or analytics storage. Searchjoy
and other analytics tools require their own integration and privacy choices;
existing Searchkick hooks should not be assumed to run for Tinkick searches.

## Autocomplete and suggestions

See the [autocomplete and suggestions reference](docs/reference/matching.md#autocomplete-and-suggestions).

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
The [captured aggregation plans](docs/aggregation-options-plans.md) verify
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

## Highlighting

See the [highlighting reference](docs/reference/results.md#highlighting).

## Similar items, geospatial, and vector search

### Similar items

`record.similar` is not implemented. A recipe can select meaningful stored terms
from a record and issue a normal search excluding its ID, or use embeddings for
semantic similarity. Neither approach reproduces a more-like-this algorithm
without defining term selection, thresholds, and ranking.

### Locations and geo shapes

`locations`, near/within filters, bounding boxes, polygons, `geo_shape`,
intersects/within/disjoint relations, and distance boosts are not implemented.
PostGIS is a possible separate PostgreSQL extension where the deployment
supports it. Store correctly typed geometry/geography, add suitable indexes via
Rails migrations, and use functions such as
[`ST_DWithin`](https://postgis.net/docs/ST_DWithin.html) in application SQL.
Coordinate reference systems and distance units are part of that design.
A bounding latitude/longitude filter can be expressed with ordinary ranges but
is not a substitute for accurate radius or polygon semantics.

### KNN, semantic, and hybrid search

`knn`, dimensions/distance configuration, HNSW `m`/`ef_construction`/`ef_search`,
semantic embedding generation, `multi_search`, and `Reranking.rrf` are not Tinkick
APIs yet. This is adapter work rather than evidence that PostgreSQL cannot serve
vector search. PlanetScale documents [TIN combined with pgvector](https://planetscale.com/docs/postgres/search#hybrid-search-with-pgvector).

Recipe architecture: add a vector column and index through migrations, generate
embeddings outside the database, run a bounded pgvector nearest-neighbor query,
and combine its IDs with a bounded lexical query. Use the same embedding model
and dimensions for documents and queries. Cosine, Euclidean, inner-product
operators and HNSW settings belong to [pgvector](https://github.com/pgvector/pgvector),
not TINQL. `Tinkick::Reranking.rrf(first_page, second_page)` combines ordered
lists and returns hashes with the original `:result` and fused `:score`.
It uses rank positions, with `k: 60` by default, and materializes its inputs;
bound each search with a limit. See [rank fusion](docs/reranking.md).
Model-based reranking still requires explicit application code.

## Pagination and large result sets

See the [pagination and large result sets reference](docs/reference/results.md#pagination-and-large-result-sets).

## Models, scopes, and tenancy

See the [models, scopes, and tenancy reference](docs/reference/querying.md#models-scopes-and-tenancy).

## Indexing and synchronization

There is no `Product.reindex`, record/association reindex, import scope,
`search_document_id`, document removal call, refresh call, or index promotion
pipeline. SQL writes update the underlying table and its indexes together:

```ruby
product.update!(name: "Green Apple")
Product.search("green apple", misspellings: false)
```

Normal transaction visibility applies. Rolled-back writes do not remain
searchable. A read replica can still lag the writer.

| Searchkick facility | Tinkick replacement |
| --- | --- |
| `search_import`, eager import scopes, batch size, resume | No document import. Backfill newly persisted columns with application migrations/jobs. |
| Inline, async, queued, manual callbacks; bulk callback blocks | No synchronization callbacks. Use ordinary SQL/ActiveRecord writes. |
| `callbacks`, `callback_options`, conditional reindex predicates | Not accepted; maintain the actual source columns when application data changes. |
| `should_index?` | Express record eligibility as SQL filters/scopes; Ruby predicates are not translated. |
| Partial reindex / `ignore_missing` | Update the relevant columns; use ordinary record-not-found/update semantics. |
| Reindex queues, queue length, job options/priority, parent job, Redis status | No search synchronization jobs or Redis requirement. Application data-maintenance jobs remain your own. |
| Parallel reindex, refresh interval, wait, promote, clean old indices | Explicit PostgreSQL index DDL and operational maintenance, not document copying. |
| `reindex(import: false)` | Create the TIN index with a Rails migration. |
| `rake searchkick:reindex:all` | Apply required Rails schema migrations. |

Changing an association does not magically update a denormalized column on another
row. Maintain that column in a transaction, callback, job, or designed database
mechanism. Existing application business callbacks still run normally; only the
extra search-document synchronization layer is absent.

Physical TIN index rebuilding still exists. It may be required when analysis
settings change or as an operational action. That is distinct from Searchkick's
Ruby document reindexing. Use reviewed Rails migrations/maintenance procedures;
TIN documents concurrent creation and rebuilding in its
[index reference](https://planetscale.com/docs/postgres/search/reference/indexes).

## Advanced SQL and debugging

Elasticsearch/OpenSearch `body`, `body_options`, body-mutating blocks, mappings,
`merge_mappings`, Painless scripts, `request_params`, and client DSL calls are
excluded. Tinkick has no `Searchkick.client` substitute. Use the application's
ActiveRecord connection for deliberate native SQL.

Recipe for a trusted TINQL query with selected columns:

```ruby
Product.where("name ==> ?", 'apple AND NOT "apple pie"')
  .select("products.id, products.name, tin.score(products.ctid) AS score")
  .order(Arel.sql("score DESC")).limit(20)
```

These return ActiveRecord projections, not `Tinkick::Relation` metadata. Missing
projected attributes remain missing. TINQL supports proximity, spans, regex,
wildcards, term ranges, minimum-match groups, and boosts beyond the current public
compiler. Consult [TINQL](https://planetscale.com/docs/postgres/search/tinql),
[operator behavior](https://planetscale.com/docs/postgres/search/reference/operator),
and [supported SQL shapes](https://planetscale.com/docs/postgres/search/reference/sql-shapes).
Keep identifiers application-controlled and bind values. SQL binding alone does
not escape TINQL metacharacters.

### Inspect analysis, score terms, and plans

Searchkick's `debug`, `explain`, and `search_index.tokens` methods are not yet
implemented. Tinkick's `response` exposes portable result metadata, not a query
plan. Recipe queries can inspect the native engine:

```sql
SELECT tin.tokenize('Jalapeño Wi-Fi')
FROM pg_extension WHERE extname = 'tin';

SELECT (tin.score_inspect('products_name_tin'::regclass, 'apple', 2)).*
FROM pg_extension WHERE extname = 'tin';

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, tin.score(ctid) AS score
FROM products
WHERE name ==> 'apple'
ORDER BY score DESC
LIMIT 20;
```

Use the actual index name. `score_inspect` reports scored terms, not all matching
terms under every stopword setting. The catalog source is intentional: the tested
PlanetScale router rejects some standalone helper/SRF SQL shapes. Inspect the
query actually executed rather than assuming every PostgreSQL expression works
through the router. See [native functions](https://planetscale.com/docs/postgres/search/reference/functions).

Tinkick publishes ActiveSupport notifications for executed operations:

| Event | Measured operation |
| --- | --- |
| `search.tinkick` | A model/raw/projected page fetch, or an unloaded raw `pluck` |
| `count.tinkick` | An explicit SQL result count |
| `aggregations.tinkick` | The requested SQL aggregations |

```ruby
ActiveSupport::Notifications.subscribe(/\.tinkick\z/) do |event|
  Rails.logger.info("#{event.payload[:name]}: #{event.duration.round(1)}ms")
end
```

Payloads contain a readable `:name` and the model name in `:model`. ActiveSupport
adds exception details when execution fails; the original error still raises.
Constructing a lazy relation and reading cached results emit no new event.
Countless pages do not emit count events unless a count is explicitly requested.
Events have their own Tinkick namespace so both gems' subscribers can coexist.

These durations cover the logical operation, which may issue several SQL queries;
use `sql.active_record` notifications and the Rails logger for SQL and query
counts. Elasticsearch request bodies are not notification payloads. Searchkick's
Lograge `searchkick_runtime`, `opaque_id`, and profiling response hooks are not
supplied.

## Performance and consistency

Single-field ranked searches use `tin.score`, descending relevance, a bounded
limit, and no unnecessary zero offset or primary-key tie sort. Integration tests
inspect native top-k plans. TIN's dense-term elision can give common words zero
score without removing matches. Scores and ties will differ from Elasticsearch;
inspect relevance on representative documents rather than asserting exact numbers.

**Multi-field cost:** Tinkick uses native `tin.score` to combine field relevance.
The current multi-index plans can still include an extra sort, so Tinkick logs
that potential cost. A historical missing-row observation led to a full-scoring
workaround; current real-TIN regression checks no longer reproduce it, so that
workaround has been removed. See the [multi-column recheck](docs/query-plans.md#multi-column-recheck).
A stored or generated combined column can provide a single-index path if its
matching semantics fit the application.

Explicit boosts, full scoring, custom SQL ranking, multiple fields, and offset
pagination can cost more than the native single-field top-k shape. Log warnings
identify native SQL paths with known costs. Native fuzzy matching
also adds work; uncapped defaults avoid a separate
candidate-enumeration pipeline but are not free. Disable misspellings when the
product requires exact lexical matching.

Warnings are enabled by default. Once you understand and accept the tradeoffs,
disable Tinkick's migration and performance warnings in an initializer:

```ruby
# config/initializers/tinkick.rb
Tinkick.warnings = false
```

Set it back to `true` to re-enable them. This setting only controls Tinkick's
warnings; application/Active Record logging and raised errors are unaffected.

See [measured query plans](docs/query-plans.md) for `EXPLAIN ANALYZE` evidence from
the real varied document corpus, including the generated SQL and machine-readable
plans. Small test-corpus timings are evidence about those plans, not throughput
or latency promises for production data.

Counts execute in SQL; they do not preload result collections. Countless and
keyset modes avoid automatic totals but still allow an explicit count. Request
only the visible page, and keep speculative UI panels or tabs from fetching their
own hidden result sets.

PostgreSQL snapshot visibility governs matches. TIN corpus statistics can retain
old entries until maintenance, so scores can change even when the visible rows
look similar. Scores belong to their query context; `ctid` is not a durable record
identifier. See [TIN scoring](https://planetscale.com/docs/postgres/search/scoring).

## Deployment and operations

Configure the Rails PostgreSQL connection and connection pool normally. Tinkick
uses that connection; `ELASTICSEARCH_URL`, `OPENSEARCH_URL`, Elastic Cloud
credentials, AWS SigV4 middleware, Bonsai/SearchBox add-ons, and multi-host HTTP
client options have no effect on it. A Heroku or other Rails deployment still
needs access to a PostgreSQL server where TIN is available.

Deploy schema changes before code requiring the new search fields. The install
generator enables an available extension; it does not provision a cluster.
Applications should refresh ActiveRecord schema caches/restart as appropriate
after changing columns or indexes. Tinkick's model validation cache follows the
connection pool and ActiveRecord column metadata.

Elasticsearch shard counts, refresh intervals, index aliases, replica counts,
index prefixes, and dynamic index names are not translated into PostgreSQL
settings. Use Rails migrations for schema, and database/provider tooling for
replication, failover, backups, and access controls. Do not expect a search-client
retry or failover layer separate from the database adapter.

TIN's [operational guidance](https://planetscale.com/docs/postgres/search/operations)
covers vacuum, write churn, replica requirements, build parallelism, and storage.
Its [limitations](https://planetscale.com/docs/postgres/search/reference/limitations)
cover partition statistics and possible replica serialization failures. Apply
appropriate transaction-level retry policies in the application; Tinkick does
not silently reroute failed queries or change cluster settings.

Use normal database TLS and role permissions, and keep credentials in your
application's secret configuration. Query logs may contain user search text;
configure filtering according to the application's requirements. Searchkick
`timeout`/`search_timeout` globals are not implemented: use connection settings
and PostgreSQL `statement_timeout` in the appropriate database/session scope.
Persistent HTTP adapters such as Typhoeus are unnecessary for this backend.

## Testing

Use a real PostgreSQL database with TIN. Do not mock PostgreSQL, TIN, or
ActiveRecord to claim search compatibility. For an application with migrated
search columns and fixtures:

```ruby
class ProductSearchTest < ActiveSupport::TestCase
  test "search sees the current database row" do
    product = Product.create!(name: "Red Apple", description: "Fresh fruit")
    assert_includes Product.search("red apple", misspellings: false).map(&:id), product.id
  end
end
```

No search callback switch, `refresh`, or reindex trait is needed. Rails fixture
transactions provide test isolation. For Minitest outside Rails or RSpec, set up
the real connection/schema and transaction cleanup explicitly. Factory Bot creates
ordinary rows; do not add Searchkick-style reindex callbacks to its factories.
Parallel workers need separate databases or another verified isolation strategy,
not Searchkick index suffixes on one shared table.

### The repository's real Rails application

The [dummy application](test/dummy) serves HTML and JSON through a controller and
registered Tinkick models. Its fixture set includes 64 deterministic synthetic
Tolkien characters generated with `Faker::Fantasy::Tolkien` and a separate
268-document search corpus: 256 varied multi-sentence records plus 12 controls
for phrase order, term frequency, document length, field boundaries, and typos.
These are synthetic test records, not assertions about Tolkien's canon.

```sh
direnv exec . bundle exec ruby -Itest test/rails_app_test.rb --fail-fast
```

The HTTP tests exercise real stored values, rendered and JSON output, filters,
bounded pages, injection-like search text, native typo matching, and visibility after
writes, plus countless navigation and cursor traversal. The development matrix
uses Ruby 4.0.1, Rails 8.0.5.1 and 8.1.3.1, with JSON 2.21.2. Remote CI has not
been run. See the tests and [development guide](docs/development.md) for current
verification commands.

A separate fixed **10,000-document** corpus uses Faker Tolkien seed 314159,
9,992 varied documents across fantasy/travel/food/technical topics, and eight
explicit controls. Its stress test passed **26 assertions** covering ranking,
unrelated text, phrases, typos, facets, keyset/countless pagination, and updates:

```sh
direnv exec . bundle exec ruby -Itest test/stress_test.rb --fail-fast
```

[Executed stress query plans](docs/query-plans.md#fixed-10000-document-corpus)
show TIN top-k for relevance/countless queries, a primary-key scan for the
match-all cursor case, and SQL aggregation over the complete corpus. These are
local regression and execution-plan results, not complete Searchkick parity or
production throughput claims.

### CI and database isolation

Repository tests use `tinkick_test`; development uses `tinkick_development`.
Standard PostgreSQL environment variables come from direnv locally. The harness
checks `current_database()` before Rails migrations, uses test-owned table names,
and requires TIN or Lead installed on the server. Keep `.envrc` and `dev.ejson`
unchanged. Separate fixture processes must not share the same test database.

Each CI matrix job runs an isolated PostgreSQL 18.6 server with
[PlanetScale Lead](https://github.com/planetscale/lead), without PlanetScale
secrets; the jobs can run in parallel. GitHub uses Docker/Buildx, while local
reproduction uses Apple's `container` tool. PostgreSQL comes from a pinned
prebuilt image. Intermediate Rust/Lead layers use the GitHub Actions cache with
`mode=max`; a warm local build reported all layers `CACHED`.

Exactly 31 observed failing tests are temporarily excluded on Lead
pending upstream fixes. Production-only plan assertions are gated separately;
both remain active against PlanetScale TIN. See [Lead CI](docs/lead-ci.md) for
the limitations and reproduction steps, and [the workflow](.github/workflows/ci.yml)
for configuration. This is not a claim that remote CI has completed.

## Reference and unsupported options

The current model declaration accepts `searchable`, `default_fields`, `match`,
the `word_start`/`word_middle`/`word_end` and `text_start`/`text_middle`/`text_end`
field declarations, and `stem: false`.
It also accepts `conversions`/`conversions_v1`, `conversions_v2`, and
`stem_conversions: false` for native JSONB conversion ranking.
The public search accepts `fields`, `where`, `order`, `limit`, `offset`, `page`,
`per_page`, `padding`, `match`, `operator`, `misspellings`, `load`, `total_entries`,
`countless`, `keyset`, `after`, `aggs`, `smart_aggs`, `includes`,
`model_includes`, `scope_results`, `block`, `exclude`, `select`, `highlight`,
`conversions`, `conversions_v1`, `conversions_v2`, and `conversions_term`.
Use the detailed sections above for their limits.
Unknown keywords or methods are not compatibility no-ops.
Features proven unsupported by TIN raise `Tinkick::NotImplementedError` with an
explanation naming the backend limitation. Unfinished Tinkick features must not
be mislabeled as TIN limitations; invalid inputs remain validation errors.

The following reference maps less common upstream options to their current status:

| Searchkick API or configuration | Status / replacement |
| --- | --- |
| `searchable`, `default_fields`, `match` | Available within the supported modes/types. |
| `filterable` | Accepts field lists and validates columns/JSONB path roots lazily. Does not limit filters or create indexes; add appropriate PostgreSQL indexes through migrations. |
| `unscope`, `inheritance`, query `type` | Not implemented as Searchkick options; define explicit model scopes and test the intended STI/tenant behavior. |
| Global `model_options` | `Tinkick.model_options` supplies defaults for subsequent declarations; explicit model values override them. |
| `search_method_name` | `Tinkick.search_method_name` selects the alias for subsequent declarations; `nil` disables alias creation. Existing methods are preserved and `tinkick_search` remains available. |
| `index_name`, dynamic names, prefix/suffix | Excluded index identity API; use explicit database/schema/table tenancy. |
| Custom `search_document_id` | Excluded document identity API; results use the model's single primary key. |
| `mappings`, `merge_mappings`, `settings` | Excluded server configuration DSL; use migrations and native index options. |
| `case_sensitive`, `special_characters` | Implemented as native index-policy validation and SQL text normalization; migrate indexes to match explicit declarations. |
| `language`, stemming options | `stem: false` is accepted. `stem: true`, `language`, `stemmer`, `stem_exclusion`, and `stemmer_override` raise `Tinkick::NotImplementedError` with migration guidance. |
| `search_synonyms`, synonym file/reload | Not implemented; application synonym storage/expansion is a recipe. |
| `conversions`, `conversions_v1`, `conversions_v2`, `conversions_term` | Native JSONB conversion ranking with field selection, term overrides and v2 factors; see the conversion contract. |
| `stem_conversions` | Nil/false accepted. Stemming requests raise `Tinkick::NotImplementedError`; persist normalized keys and provide their lookup term. |
| `exclude` | Available across selected fields; exact phrase negatives with mode-specific matching. |
| `suggest`, `similar`, `emoji` | Not implemented; see the corresponding recipes. |
| `locations`, `geo_shape`, `knn` | Not implemented; design explicit PostGIS/pgvector integration where available. |
| `callbacks`, queues, job priorities/parent jobs | Excluded synchronization configuration. |
| Import batch size, resume, partial/bulk reindex | Excluded document import API; update real data with application jobs/migrations. |
| Routing, request parameters, opaque IDs | Excluded transport API; use SQL filters, database routing, and Rails instrumentation. |
| `timeout`, `search_timeout`, `client_options` | Not implemented; configure database timeouts/pooling. |
| `includes`, `model_includes` | Available; preload only visible model results. |
| `scope_results` | Available; filters the ranked page with an extra query and warning. |
| `select`, source filtering, `reselect` | Available for top-level columns and nested JSON source filtering; model loading remains complete. |
| `only`, `except` | Available for query-option selection/removal; these do not select model columns. |
| `body`, `body_options`, body-mutating blocks | Elasticsearch DSL is excluded. Use `block:` or a Ruby block to transform the Active Record relation with SQL/Arel. |
| `search_index`/`searchkick_index` inspection | Not implemented; use PostgreSQL catalogs and TIN helpers. |
| Index refresh, clean/promote/store/remove, queue inspection | Excluded external-index lifecycle. |
| Global search | Available with an explicit `model:`; preserves generic search-method ownership. |
| `multi_search`, `models`, model boosts | Not implemented; separate queries or explicit SQL combination. |
| Scroll/deep-paging configuration | Excluded backend APIs; use bounded column cursors or SQL batches. |
| BigDecimal serialization rules | No JSON document conversion: PostgreSQL column types govern stored precision. |
| Mongoid | Unsupported integration; Tinkick requires ActiveRecord with PostgreSQL. |
| Searchjoy, Autosuggest, Kaminari, will_paginate, Apartment | Not bundled or claimed fully compatible; verify each integration explicitly. |

See [the compatibility inventory](docs/compatibility.md) for the wider API target,
[TIN evidence](docs/tin-api.md) for verified native behavior, and
[the implementation plan](docs/plan.md) for remaining work. “Not implemented” is
not a promise of a release date and should not be relabeled a TIN limitation.

## Development, upgrades, and contributing

Keep the existing `.envrc` and `dev.ejson` local. They supply development/test
connection settings, are excluded from Git and the gem, and must not be replaced
or printed during setup. Requiring the gem and unit/boot checks do not require a
live database; integration tests do.

```sh
direnv exec . bundle install
direnv exec . bundle exec rbs collection install
direnv exec . bundle exec rubocop -A Gemfile tinkick.gemspec Rakefile Steepfile lib test
direnv exec . bundle exec rake rbs:format rbs:quality
direnv exec . bundle exec rake
direnv exec . bundle exec rake build
```

`rake` runs the combined fail-fast Minitest suite, RuboCop, RBS validation, and
Steep. `rake build` produces `pkg/tinkick-0.1.0.alpha.1.gem`. `Gemfile.lock` is local
and ignored so supported dependency ranges can be exercised. CI uses Bundler
directly rather than a local `.envrc`.

Contributions should pair behavior changes with meaningful tests against real
TIN, keep RBS and RuboCop synchronized, and use reviewable Conventional Commits.
Report the Ruby/Rails/PostgreSQL/TIN versions, reproducible query, schema, and
actual plan when reporting a search bug; omit credentials and private records.

Upgrading from Searchkick 5 or 6 is a backend migration, not merely a gem version
change. Audit model options, derived fields, query methods, result consumers,
background jobs, and relevance expectations. The supported keyword/fluent APIs
cover part of Searchkick 6's builder interface. Migrate conversion columns with
Rails and select v2 explicitly as described above; Searchkick's index upgrade
tasks are not Tinkick procedures. Follow
[CHANGELOG.md](CHANGELOG.md) for Tinkick changes and rerun application search
contracts before upgrading an alpha release.

Thanks to the Searchkick project for the API this gem aims to preserve, and to
the PlanetScale TIN team for the PostgreSQL search engine and reference material.

## License

[MIT](LICENSE.txt), copyright 2026 yknx4.
