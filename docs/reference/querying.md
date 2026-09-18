# Query and model reference

[Back to the guide](../../README.md)

- [Querying](#querying)
- [Models, scopes, and tenancy](#models-scopes-and-tenancy)

## Querying

Both keyword options and the implemented fluent modifiers are available:

```ruby
Product.search("apple", fields: [:name], where: { in_stock: true }, limit: 10)
Product.search("apple", fields: [:name]).where(in_stock: true).limit(10)
Product.search("apple", fields: [:name]).operator("or").misspellings(false)
```

The default query is `"*"`, the default operator is `"and"`, misspellings are
on, and the default limit is **10,000**. Set a smaller limit for user-facing pages.
Empty or punctuation-only text matches no records. Only a standalone `*` means
match all. Ordinary search text is treated literally rather than as raw TINQL;
quotes, `OR`, wildcard characters, and SQL fragments do not inject operators.

### Fields

Field selection precedence is: the search call's `fields`, model `default_fields`,
model `searchable`, then eligible `text`/`citext` columns from the datasource.
Selected fields need TIN indexes; filtering columns do not.

```ruby
Product.search("apple", fields: [:name])
Product.search("apple", fields: [:name]).fields(:description)
```

The fluent `fields` method **appends** fields. Use the keyword form to replace the
model's defaults. Per-field match hashes and dotted JSONB scalar paths are
available. Boosted names such as `"name^5"` weight that field's native relevance.

`fields: ["*"]` searches declared `searchable` fields, or eligible text columns
when none are declared. Leading `*.` patterns also expand known dotted paths:
`fields: ["*.title"]` includes a declared `metadata.title`. They never discover
arbitrary JSON keys. Partial match patterns expand fields configured for that
mode; exact-mode `"*"` and patterns such as `"na*"` remain literal field names,
matching Searchkick's field handling. An unmatched pattern has no lexical hits.
Per-field misspelling restrictions must use the original selector, for example
`fields: ["*"], misspellings: {fields: ["*"]}`.

### Search across columns

Index each searched column separately, then pass them in `fields`:

```ruby
# Migration: one TIN index per text column
add_index :products, :name, using: :tin
add_index :products, :description, using: :tin

# Search: a name match contributes 1.5 times its unboosted relevance
products = Product.tinkick_search("fuji apple",
  fields: ["name^1.5", :description], misspellings: false,
  where: { in_stock: true }, highlight: true, limit: 20, countless: true)
products.with_score.each { |product, score| puts [product.name, score].inspect }
products.highlights
```

The generated SQL combines one `==>` predicate per field with `OR`. A row
matching either field qualifies, a row matching both appears once, and native
`tin.score` adds the matching fields' relevance. Field weights use TINQL `^N`;
zero keeps matches while removing that field's score contribution. Boosts from
0 through 10000 stay native. See [boosting](../../README.md#boosting-conversions-and-personalization)
for larger factors and SQL ranking costs.

The default `operator: "and"` requires all words in at least one selected field.
It does not split required words across fields. Use a stored/generated combined
column for that behavior, or `operator: "or"` if any query word is sufficient.
Phrases likewise stay within a field. Filters, explicit `total_count`, highlights,
countless pages, and column-based keyset cursors work with multiple fields.

PlanetScale also shows **different queries required in different columns**.
For that SQL `AND` shape, use ordinary Active Record with bound native TINQL:

```ruby
Product.where("name ==> ? AND description ==> ?", "fuji^1.5", "citrus")
  .select("products.*, tin.score(products.ctid) AS relevance")
  .order(Arel.sql("relevance DESC")).limit(20)
```

This is native TINQL; `tinkick_search` continues to treat search text literally.
See [PlanetScale's multi-column guide](https://planetscale.com/docs/postgres/search/get-started#search-across-columns)
and our [executed multi-column checks](../../docs/query-plans.md#multi-column-recheck).

### Laziness and modifiers

A `Tinkick::Relation` defers record retrieval until enumeration or loading. Model
schema validation may execute metadata queries when creating the search.

```ruby
base = Product.search("apple", fields: [:name])
filtered = base.where(in_stock: true) # Independent clone
filtered.load                       # Executes and returns the relation
filtered.loaded?                    # true
filtered.first                      # A model or nil
base.first(3)                       # Retrieves a bounded clone
```

Non-bang modifiers clone; their bang counterparts mutate an unloaded relation
and reject mutation after loading. Repeated `where` calls combine constraints;
`rewhere` replaces them. `order` appends sort terms; `reorder` replaces them.
`clone` and `dup` produce independent, unloaded relations.

### Active Record, SQL and Arel

For tested custom ranking and grouping recipes, see [Custom search](../../docs/custom-search.md).

Start from an Active Record scope, or merge one into a search. Its filters apply
to matching, typo fallback, counts and aggregations:

```ruby
search = Product.where("price >= ?", 10).tinkick_search("coffee")
search = search.merge(Product.where(Product.arel_table[:in_stock].eq(true)))
rows = search.to_relation.where("price < ?", 50).includes(:category)
```

`to_relation` returns a normal, lazy `ActiveRecord::Relation`, with the search
score selected as `_tinkick_score`. It supports SQL/Arel, joins, CTEs and normal
Active Record methods. Tinkick controls its initial projection, ordering and page;
use `reselect`, `reorder` or `limit` on the native relation to replace them.
For SQL grouping before pagination, use `.except(:limit, :offset, :order)`.
Native relations return models; Tinkick's raw-result wrappers, highlighting and
pagination metadata apply only when executing the Tinkick search itself.

Use `block:` (including a lambda in an options hash) or a Ruby block to change
that relation **before pagination**:

```ruby
Product.tinkick_search("coffee", block: ->(query) { query.where(in_stock: true) })
Product.tinkick_search("coffee") do |query|
  query.where(Product.arel_table[:price].lt(20)).reorder(popularity: :desc)
end
```

Return an Active Record relation for the same model. Keep its primary key and
`_tinkick_score` projection; use `reselect` to replace the score for custom SQL
ranking. Counts, typo thresholds and aggregations include the hook. It can run
more than once, so keep it a query transformation without side effects. This
also works with `Tinkick.search(model: Product, ...)`.

Tinkick applies page limits/offsets after the hook. Keyset pagination reapplies
its configured column order so the cursor remains valid. Unlike this hook,
`scope_results` filters an already-selected page. With a hook, `select`/`pluck`
preserve its SQL projection and trim columns in Ruby (with a disableable warning);
put `reselect` inside the hook to reduce data transfer.

### Ordering and projection

The default is native relevance descending. Explicit ordering accepts real
column names, `_score`, and `asc`/`desc` directions:

```ruby
Product.search("apple").order(price: :asc, id: :asc)
Product.search("apple").order(:name).reorder(created_at: :desc)
Product.search("apple").order(_score: :desc)
Product.search("apple").order(_score: :desc, id: :asc)
```

Descending score order retains the native relevance path. Ascending scores or
column tiebreakers can require a sort and log a cost warning. In the 268-document
ranking fixture, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for explicit descending
score order with `limit: 2, countless: true` showed a TIN Text Search Scan with
`Top K: 3` and no Sort node; the regression test checks this live.

Prefer explicit directions. Searchkick's scalar keyword `order: :_score` means
ascending, while `order: [:_score]` and fluent `.order(:_score)` mean descending.
Keyset pagination still requires stable columns. Arbitrary SQL sort expressions,
Elasticsearch missing-value rules, and nested sorts remain adapter work.

For raw results, `select` limits source columns in SQL and `reselect` replaces
the selection:

```ruby
Product.search("apple", load: false, select: [:name, :price])
Product.search("apple").load(false).select(:name).select(:price).reselect(:name)
Product.search("apple", load: false, select: {includes: ["name", "meta*"], excludes: "metadata_private"})
Product.search("apple", load: false,
  select: {includes: ["metadata.origin.city", "metadata.people.name"], excludes: "*.secret"})
```

Source filters support column names, dotted JSON properties, and `*` patterns.
Selecting an object includes its descendants; exclusions take precedence.
Arrays of objects retain their structure, removing objects with no selected
properties. Nulls, false values, and explicitly selected empty containers survive.
The primary key remains available as result identity; extra keyset ordering
columns stay hidden. PostgreSQL arrays and complete JSONB columns retain their
Ruby values. Nested selection projects eligible root columns in SQL and prunes
their JSON within the bounded result page. It logs a cost warning because a
large JSON column still travels over the connection; use stored or generated
columns for frequent narrow projections. An empty list returns identity only;
`select: nil`, `true`, or `false` keeps all raw fields, following Searchkick's
request behavior. Normal model results retain complete attributes and association
preloading. `select { |record| ... }` performs Enumerable selection on the page.

`only(:where, :limit)` retains those query options; `except(:order, :fields)`
removes them. Both return an unloaded search with the same model and term,
restoring omitted options to their model or query defaults. They work on loaded
relations too and preserve the original. These methods filter options; use
`select` for source projection. `map(&:name)` reads the loaded page. `load: false`
still logs its migration warning.

## Models, scopes, and tenancy

### Default scopes, associations, and inheritance

Search queries start from the model's ActiveRecord scope, including default
scopes. Registration is inherited by subclasses. Native ActiveRecord STI is
tested for parent, child, and grandchild queries: a child searches its own rows
and descendants, and model results retain their concrete classes. Counts,
terms/dictionaries, metrics, ranges, and histograms keep those STI restrictions.
Searchkick's `inheritance:` and query `type` options are not implemented; these
native model queries do not claim Elasticsearch document-type parity.

Use model filters or an Active Record scope:

```ruby
Product.search("apple", where: { store_id: store.id })
Product.where(store_id: store.id).tinkick_search("apple")
```

Use `tinkick_search` explicitly when Searchkick also owns the `search` alias.
`includes` and `model_includes` preload real ActiveRecord associations only for
the visible model results. Nested associations are supported. The extra probe
row used by countless/keyset pagination is not preloaded.

```ruby
Product.search("coffee", includes: [:store, {reviews: :author}], limit: 20)
Product.search("coffee").includes(:store).includes(reviews: :author)
Product.search("coffee", model_includes: {Product => [:store]})
```

`.includes` appends associations; `.model_includes` merges per-model mappings.
Their bang forms mutate only an unloaded relation. `model_includes` entries for
other model classes are ignored by a single-model search. Generic and applicable
model-specific associations are combined. `load: false`, count-only access, and
empty result pages do not preload associations.

`scope_results` filters the already-ranked visible page through an ActiveRecord
scope, keeping hit order and scores:

```ruby
Product.search("coffee", scope_results: ->(scope) { scope.where(in_stock: true) })
Product.search("coffee").scope_results(->(scope) { scope.where(in_stock: true) })
```

This logs a warning about an extra page-bounded query. Prefer search `where:`
when possible: `scope_results` does not refill a shortened page or change the
original total. Associations preload only surviving records. It is ignored for
`load: false` and count-only access; cursor progression follows the original
ranked page even when the callback removes all its records.

### Multiple models and multi-search

Global search supports an explicitly registered model and uses its
`tinkick_search` entry point, so an existing generic `search` method is preserved:

```ruby
Tinkick.search("coffee", model: Product, where: {in_stock: true}, limit: 20)
```

Combined `models`, `indices_boost`, and `Tinkick.multi_search` remain adapter
work. Query each model explicitly, or design a SQL `UNION ALL` over
compatible projected columns. Combining independently ranked lists requires a
ranking policy; concatenating them is not a global relevance ranking. Batched
error handling is also an application concern, especially inside transactions.

### Tenants and nested data

Searchkick index names, prefixes, suffixes, and routing do not isolate PostgreSQL
rows. Pass a tenant filter on every query or use an application database/schema
routing design. [PostgreSQL row security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
can provide another boundary where correctly configured; Tinkick does not install
policies or verify an Apartment integration.

JSONB filter paths such as `store.city` are supported as described under
[filtering](filtering.md#filtering). Text search also accepts dotted scalar paths:

```sh
bin/rails generate tinkick:index products metadata.title metadata.details.summary
bin/rails db:migrate
```

```ruby
class Product < ApplicationRecord
  tinkick searchable: ["metadata.title", "metadata.details.summary"]
end

Product.search("voyage", fields: ["metadata.title"])
Product.search("Voyage to Gondor", fields: [{ "metadata.title" => :exact }])
```

Each native search path requires its own valid, nonpartial TIN expression index.
The generator emits nested `->` access followed by `->>` for the leaf. Registration
checks the actual indexed expression; an index on another path does not qualify.
Strings, numbers, and booleans search their text representation. Objects, arrays,
missing paths, and JSON null do not match scalar text search. Exact and whole-field
SQL match modes do not require a TIN index. Updating JSONB updates its expression
indexes within the same transaction.

`tinkick_search_data` validates physical column names: return the `metadata`
column key, not dotted virtual keys. Use persisted or generated text columns when
you need custom normalization or a combined document. Flattened array-of-object
filters do not preserve same-object correlation; use explicit `EXISTS`/joins or
JSON predicates when that distinction matters.
