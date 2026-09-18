# Tinkick

Searchkick-style search for **Ruby 4+ and Rails 8+**, powered by
[PlanetScale TIN](https://planetscale.com/docs/postgres/search).
Search your PostgreSQL tables directly. Writes update the search indexes—no
separate document store, reindex jobs, or Elasticsearch client.

**Alpha:** full-text, phrase and partial matching, typo tolerance, filters,
boosts, highlighting, facets, and cursor pagination are available. Tinkick favors
native TIN performance over identical Elasticsearch scores. Both gems can run
[side by side](#migrating-from-searchkick).

[Get started](#getting-started) · [Search](#searching) · [Filter](#filtering) ·
[Rank](#ranking) · [Paginate](#pagination) · [SQL](#active-record-and-sql) ·
[Reference](#reference)

## Getting started

You need PostgreSQL with TIN installed on the server; standard PostgreSQL does
not include it. For local testing, see [Lead setup](docs/lead-ci.md).

Add your checkout to the application's Gemfile, then run `bundle install`:

```ruby
gem "tinkick", path: "../tinkick"
gem "json", "< 3" # Required by the verified Rails 8.0.5.1 / 8.1.3.1 versions
```

Enable TIN and index your existing `text` or `citext` columns:

```sh
bin/rails generate tinkick:install
bin/rails db:migrate
bin/rails generate tinkick:index products name description
bin/rails db:migrate
```

Declare the searchable fields:

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:name, :description], default_fields: [:name]
end
```

Then search the rows already in your database:

```ruby
products = Product.search("coffee").where(in_stock: true).limit(20)
products.each { |product| puts product.name }
```

Examples below assume `Product` also has `in_stock` (boolean), `price` (numeric),
`category` (text), `orders_count` (numeric), and `created_at` (timestamp).
Use Rails migrations to add any missing columns. The first search validates
fields and indexes; declaring `tinkick` does not connect or change the schema.

No `reindex` call is needed. Optional extensions are required only by features
that use them. [Installation, generators, and computed fields →](docs/reference/installation.md)

## Searching

Match all words, any word, or an ordered phrase:

```ruby
Product.search("coffee beans", misspellings: false)
Product.search("coffee tea", operator: "or", misspellings: false)
Product.search("coffee beans", match: :phrase)
```

Search selected fields, or all rows:

```ruby
Product.search("coffee", fields: [:name, :description])
Product.search("*").where(in_stock: true).limit(20)
```

With multiple fields, **all words must match within one field** by default.
A stored/generated combined column lets words match across the original columns.
Matching several fields returns each row once and adds their relevance scores.

Search text is literal, not raw TINQL. Only a standalone `*` means “all rows”;
empty or punctuation-only input matches nothing. Queries are lazy, and fluent
modifiers return independent searches. The default limit is 10,000—set a smaller
limit for pages. [Fields, scopes, modifiers, and ordering →](docs/reference/querying.md)

### Misspellings

Native typo tolerance is on by default. Disable it or enable it only when too
few exact matches exist:

```ruby
Product.search("cofee")
Product.search("coffee", misspellings: false)
Product.search("cofee", misspellings: { below: 5 }, limit: 20)
```

`below` adds a bounded count query. Native defaults may find more typo matches
than Searchkick; expansion caps and single-edit transpositions are unsupported.
[Distances, prefixes, and per-field controls →](docs/reference/matching.md#misspellings)

### Partial matches and autocomplete

```ruby
Product.search("cof", match: :word_start, misspellings: false, limit: 10).pluck(:name)
Product.search("off", match: :word_middle, misspellings: false)
Product.search("fee", match: :word_end, misspellings: false)
Product.search("Coffee Beans", match: :exact)
```

Token partial matching uses TIN wildcards and requires misspellings off.
`:exact` is case-sensitive whole-field equality. Whole-field prefixes/substrings
use `:text_start`, `:text_middle`, or `:text_end`; these use SQL and may need
`unaccent`. [All match modes and analysis settings →](docs/reference/matching.md)

### TINQL extensions

Use `tinql:` or `.tinql(...)` for **TINQL-specific features that may have no
Searchkick equivalent**:

```ruby
Product.search(tinql: { near: ["coffee", "beans"], distance: 2 })
Product.search(tinql: { at_least: ["coffee", "beans", "roasted"], count: 2 })
Product.search("coffee").tinql(in_first: "beans", words: 20)
```

Compose literal strings and expression hashes. Phrase gaps, alternatives,
proximity, spans, positions, token patterns, ranges, and expression boosts run
natively in TIN. [Complete API and examples →](docs/tinql.md)

## Filtering

Combine filters with a search. Keyword and fluent forms are equivalent:

```ruby
Product.search("coffee", where: { in_stock: true, price: { lte: 25 } })
Product.search("coffee").where(in_stock: true).where(price: 10..25)
```

| Filter | Example |
| --- | --- |
| Equal / missing | `.where(category: "drinks")`, `.where(category: nil)` |
| Not equal | `.where.not(category: "equipment")` |
| Any listed value | `.where(category: ["drinks", "equipment"])` |
| Comparisons | `.where(price: { gt: 10, lte: 25 })` |
| Range | `.where(price: 10...25)` |
| Exists | `.where(category: { exists: true })` |
| Case-insensitive pattern | `.where(name: { ilike: "%coffee%" })` |
| Native PostgreSQL regex | `.where(name: { regexp: "(?i)^organic" })` |
| OR | `.where(_or: [{ in_stock: true }, { price: { lt: 10 } }])` |

Filters also support enums, PostgreSQL arrays and dotted JSONB paths. Regex
patterns are PostgreSQL strings; Ruby `Regexp` objects are not supported.
Add ordinary PostgreSQL indexes for frequently used filters.
[Complete filter semantics and examples →](docs/reference/filtering.md)

## Ranking

Results are ordered by relevance. Give a field more weight:

```ruby
Product.search("coffee", fields: ["name^5", :description])
```

Boost popular, matching, or recent records:

```ruby
Product.search("coffee", boost_by: { orders_count: { factor: 2 } })
Product.search("coffee", boost_where: { in_stock: { value: true, factor: 3 } })
Product.search("coffee", boost_by_recency: { created_at: { scale: "7d" } })
```

Use explicit ordering when relevance is not the primary sort:

```ruby
Product.search("coffee").order(price: :asc, id: :asc)
```

Field weights up to 10,000 use native TIN boosts. Numeric, conditional, recency,
and custom SQL ranking may sort all matches and log cost warnings. Scores and
tied ordering can differ from Elasticsearch.
[Formulas, JSONB conversions, personalization, and rank fusion →](docs/reference/ranking.md)

## Results

Searches return a lazy `Tinkick::Relation` containing Active Record models:

```ruby
results = Product.search("coffee", limit: 20, countless: true)
results.each { |product| puts product.name }
results.size         # Records on this page
results.total_count  # All matching rows; runs a count query
results.pluck(:id, :name)
results.with_score.each { |product, score| puts "#{product.name}: #{score}" }
```

`load: false` returns hash-style rows for compatibility. It still queries through
Active Record and is not a performance shortcut; Tinkick logs a migration warning.
[Projection, hits, and response metadata →](docs/reference/results.md)

### Highlighting

```ruby
results = Product.search("coffee", limit: 20,
  highlight: { encoder: "html", fields: [:name] })
results.highlights # [{ name: "Organic <em>Coffee</em>" }, ...]
```

`encoder: "html"` escapes stored text separately from highlight tags. Results
are not marked HTML-safe. Native highlighting requires default index analysis;
custom-tokenizer searches remain available without it.
[Fragments, per-field options, and highlight metadata →](docs/reference/results.md#highlighting)

## Pagination

Use **keyset pagination** for deep browsing with a stable column order:

```ruby
search = Product.search("coffee", order: { id: :asc }, limit: 20)
first_page = search.keyset

if (cursor = first_page.next_cursor)
  next_page = search.keyset(after: cursor)
end
```

Keyset pages avoid offsets and automatic counts. Sort columns must be supported,
nonnullable scalars; relevance scores cannot be cursor keys. Reapply the same
query, filters, authorization and order on every request. A cursor is not a snapshot.

Keep relevance ordering with **countless pagination**:

```ruby
page = Product.search("coffee", limit: 20, countless: true)
page.has_next_page? # Uses one extra row, without counting all matches
page.next_page
```

Traditional pages remain available:

```ruby
Product.search("coffee").page(2).per_page(20)
```

Later numbered pages still pay offset costs, even with `countless: true`.
Requesting a total adds a count query unless `total_entries:` is supplied.
[Cursor rules, metadata, offsets, and exports →](docs/reference/results.md#pagination-and-large-result-sets)

## Aggregations

Request facets and metrics over matching rows, independently of the result page:

```ruby
results = Product.search("coffee", limit: 20, aggs: {
  category: { limit: 10 },
  average_price: { avg: { field: :price } }
})

results.aggs["category"]["buckets"]
results.aggs["average_price"]["value"]
```

Smart facets ignore their own top-level filter by default. Keep authorization
in the starting model scope so a facet cannot remove it. Aggregations run in
PostgreSQL without loading every matching model.
[Smart facets, arrays, missing values, ranges, and histograms →](docs/reference/aggregations.md)

## Active Record and SQL

Start from a scope, merge another scope, or get the native relation:

```ruby
search = Product.where(in_stock: true).tinkick_search("coffee", limit: 20)
search.merge(Product.where(price: 10..25))
search.to_relation.where("price < ?", 20)
```

Use a Ruby block—or `block: ->(query) { ... }`—to change the scored relation
**before pagination**:

```ruby
Product.tinkick_search("coffee", limit: 20) do |query|
  query.where("price < ?", 20).reorder(orders_count: :desc)
end
```

Return a relation for the same model, retaining its primary key and
`_tinkick_score`. Counts, typo thresholds and aggregations include the hook;
it may run more than once, so keep it free of side effects. Arel, joins, CTEs
and SQL window functions remain available through Active Record.
[Hook contract](docs/reference/querying.md#active-record-sql-and-arel) ·
[Tested custom ranking and grouping recipes](docs/custom-search.md)

## Migrating from Searchkick

Keep both declarations and choose the backend explicitly:

```ruby
class Product < ApplicationRecord
  searchkick searchable: [:name]
  tinkick searchable: [:name]
end

Product.searchkick_search("coffee")
Product.tinkick_search("coffee")
```

Tinkick defines `search` only if it is free. `tinkick_search` is always available;
use it during migration regardless of declaration order.

The table is the datasource. Move computed search values into persisted or
[generated columns](docs/reference/installation.md#computed-fields-and-generated-columns).
The optional `tinkick_search_data` hook validates column names on a new, unsaved
instance; its values are never indexed. With Searchkick installed, Tinkick leaves
`search_data` to Searchkick. There are no replacement reindex jobs or callbacks.

| Difference | Replacement |
| --- | --- |
| Raw Elasticsearch bodies, mappings, scripts and routing | SQL/Arel, relation hooks, Rails migrations and tenant scopes |
| Stemming and Elasticsearch fuzzy controls | Native TIN matching or application-normalized columns; unsupported TIN features raise `Tinkick::NotImplementedError` |
| Synonyms, suggestions and similar-item API | Application-owned normalization/query expansion or similarity queries; these APIs are not implemented |
| Geospatial, KNN and multi-model search APIs | Explicit PostGIS/pgvector/SQL queries where available; these integrations are not implemented |
| Search synchronization and index lifecycle APIs | Ordinary writes, data backfills and PostgreSQL index maintenance |

Missing Tinkick APIs do not imply that PostgreSQL cannot implement the behavior.
[Migration guide](docs/migrating-from-searchkick.md) ·
[Full API status and alternatives](docs/reference/compatibility.md)

## Performance and operations

Bound pages, index filters, and inspect `EXPLAIN (ANALYZE, BUFFERS)` on representative
data. Native single-field relevance can use TIN top-k; multi-field search, custom
ranking, grouping and offsets may need extra work. [Measured plans →](docs/query-plans.md)

Warnings describe migration and performance tradeoffs. Disable them after
accepting those tradeoffs:

```ruby
Tinkick.warnings = false
```

This does not suppress errors or application logs. Normal transaction visibility
and replica lag apply; scores can change as TIN statistics change. Deploy schema
changes before code that uses them, and configure connections, timeouts and
retries through Rails/PostgreSQL.
[Debugging, instrumentation, deployment, and maintenance →](docs/reference/operations.md)

## Reference

All detailed API contracts, edge cases, backend differences and recipes live here:

| Topic | Details |
| --- | --- |
| [Installation and schema](docs/reference/installation.md) | Requirements, generators, aliases, defaults, schema checks, computed fields |
| [Queries and models](docs/reference/querying.md) | Field selection, modifiers, SQL hooks, projections, preloads, STI, tenancy, JSONB search |
| [Filters](docs/reference/filtering.md) | NULLs, negation, enums, arrays, JSONB, native patterns |
| [Matching](docs/reference/matching.md) | Phrases, typos, partial/exact modes, analysis, exclusions, autocomplete |
| [Ranking](docs/reference/ranking.md) | Field/numeric/conditional/recency boosts, conversions, similarity, vectors |
| [Results and pagination](docs/reference/results.md) | Raw rows, hits, timings, highlights, totals, cursors, exports |
| [Aggregations](docs/reference/aggregations.md) | Terms, metrics, ranges, histograms, time zones, bounds |
| [Operations](docs/reference/operations.md) | Writes, native SQL, diagnostics, notifications, performance, deployment |
| [Compatibility](docs/reference/compatibility.md) | Supported options, unsupported features, replacements |
| [Testing and contributing](docs/reference/testing.md) | Real database tests, datasets, CI, checks, upgrades |

## Contributing

Use real PostgreSQL/TIN tests and varied data. The test Rails app covers HTTP
requests, ranking and filters; CI uses isolated, cached Lead containers with
[explicit limitations](docs/lead-ci.md). Production-plan checks use real TIN.

See [development setup and checks](docs/development.md), the
[implementation plan](docs/plan.md), and [changelog](CHANGELOG.md).

Thanks to Searchkick for the API inspiration and PlanetScale for TIN.
[MIT license](LICENSE.txt) © 2026 yknx4.
