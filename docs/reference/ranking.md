# Ranking reference

[Back to the guide](../../README.md)

- [Boosting, conversions, and personalization](#boosting-conversions-and-personalization)
- [Similar items, geospatial, and vector search](#similar-items-geospatial-and-vector-search)

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
[native and SQL weight plans](../../docs/query-plans.md#native-and-sql-field-weights)
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
See the [native recency query plans](../../docs/recency-plans.md) for a reproducible
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
[conversion contract](../../docs/conversions-contract.md) and
[reproducible query plans](../../docs/conversion-plans.md).

### Conversion tracking

`track` and Searchjoy integration are not implemented. Applications own event
storage, count aggregation and column updates; updating conversion counts needs
no search-document reindex.

The gem creates no conversion cron jobs, queues, or analytics storage. Searchjoy
and other analytics tools require their own integration and privacy choices;
existing Searchkick hooks should not be assumed to run for Tinkick searches.

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
semantic embedding generation, and `multi_search` are not Tinkick APIs yet. This
is adapter work rather than evidence that PostgreSQL cannot serve
vector search. PlanetScale documents [TIN combined with pgvector](https://planetscale.com/docs/postgres/search#hybrid-search-with-pgvector).

Recipe architecture: add a vector column and index through migrations, generate
embeddings outside the database, run a bounded pgvector nearest-neighbor query,
and combine its IDs with a bounded lexical query. Use the same embedding model
and dimensions for documents and queries. Cosine, Euclidean, inner-product
operators and HNSW settings belong to [pgvector](https://github.com/pgvector/pgvector),
not TINQL. `Tinkick::Reranking.rrf(first_page, second_page)` combines ordered
lists and returns hashes with the original `:result` and fused `:score`.
It uses rank positions, with `k: 60` by default, and materializes its inputs;
bound each search with a limit. See [rank fusion](../../docs/reranking.md).
Model-based reranking still requires explicit application code.
