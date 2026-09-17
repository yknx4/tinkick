# Tinkick

Searchkick-style search for Ruby and Rails, backed by
[PlanetScale TIN](https://planetscale.com/docs/postgres/search). Your model's
PostgreSQL table is the datasource. PostgreSQL maintains the search indexes when
rows change; there is no second document store to synchronize.

**Status: alpha.** The implemented API covers model registration, lazy search
relations, word and phrase queries, distance-one typo matching, scalar filters,
ordering, model/raw-row results, and pagination. This is a compatibility project,
not yet a complete drop-in replacement. This guide covers the feature surface of
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

- [Requirements and installation](#requirements-and-installation)
- [Getting started](#getting-started)
- [Migrating alongside Searchkick](#migrating-alongside-searchkick)
- [Datasource and migrations](#datasource-and-migrations)
- [Querying](#querying)
- [Results and metadata](#results-and-metadata)
- [Filtering](#filtering)
- [Matching and analysis](#matching-and-analysis)
- [Boosting, conversions, and personalization](#boosting-conversions-and-personalization)
- [Autocomplete and suggestions](#autocomplete-and-suggestions)
- [Aggregations and facets](#aggregations-and-facets)
- [Highlighting](#highlighting)
- [Similar items, geospatial, and vector search](#similar-items-geospatial-and-vector-search)
- [Pagination and large result sets](#pagination-and-large-result-sets)
- [Models, scopes, and tenancy](#models-scopes-and-tenancy)
- [Indexing and synchronization](#indexing-and-synchronization)
- [Advanced SQL and debugging](#advanced-sql-and-debugging)
- [Performance and consistency](#performance-and-consistency)
- [Deployment and operations](#deployment-and-operations)
- [Testing](#testing)
- [Reference and unsupported options](#reference-and-unsupported-options)
- [Development, upgrades, and contributing](#development-upgrades-and-contributing)
- [License](#license)

## Requirements and installation

- Ruby **4.0+**.
- Rails / ActiveRecord **8.0+**, using the PostgreSQL adapter.
- PostgreSQL with the **TIN extension available on the server**. A standard local
  PostgreSQL installation does not include TIN.
- Searchable columns of type `text` or `citext`, with one TIN index per column.

ActiveRecord, `pg`, and `base64` are runtime dependencies. Rails is used for integration and
migration generators; Elasticsearch and OpenSearch clients are not required.
The version ranges permit future Ruby and Rails releases but do not claim they
have already been tested. The CI matrix targets Ruby 4.0 with Rails 8.0 and 8.1.

For a local checkout, add:

```ruby
# Gemfile
gem "tinkick", path: "../tinkick"
```

Then run `bundle install`. The repository can also build an installable gem with
`bundle exec rake build`; publication to RubyGems is a separate release step.

**Rails JSON compatibility:** the verified Rails 8.0.5.1 and 8.1.3.1 releases
need `gem "json", "< 3"` in the application Gemfile. Rails 8.0 encoding and
Rails 8.1 JSONB decoding call interfaces changed by JSON 3. The development
matrix uses JSON 2 for both Rails versions. Tinkick does not patch Rails' JSON
handling; newer Rails releases should be checked before removing this constraint.

## Getting started

Enable TIN through a Rails migration:

```sh
bin/rails generate tinkick:install
bin/rails db:migrate
```

Optional search helpers are opt-in. Install only those used by your application:

```sh
bin/rails generate tinkick:install --unaccent --pg-trgm
```

The default generator enables only TIN. Optional extensions are checked when a
feature uses them; they do not block loading the gem or ordinary TIN searches.
A missing dependency raises `Tinkick::Error` with the required `enable_extension`
Rails migration. If an installation migration already exists, add a new
application migration rather than replacing that migration.

The `--fuzzystrmatch` option is also available for application SQL. Tinkick's
fuzzy matching uses TIN and does not use this extension.

For existing `text` columns, generate the indexes:

```sh
bin/rails generate tinkick:index products name description
bin/rails db:migrate
```

Declare the model:

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:name, :description], default_fields: [:name]
end
```

Search existing records immediately after the migrations:

```ruby
products = Product.search("apple").where(in_stock: true).limit(20)
products.each { |product| puts product.name }

Product.search("red apple", fields: [:name], misspellings: false)
Product.search("*").order(name: :asc).limit(20)
```

`name`, `description`, and `in_stock` in these examples must be real columns.
Do not call `reindex`: the table is already the source of searchable records.
Model declaration does not connect to PostgreSQL or change the schema. The first
search validates the extension, fields, and usable indexes; missing schema
produces migration guidance.

## Migrating alongside Searchkick

Both gems can remain installed while you compare results:

```ruby
class Product < ApplicationRecord
  searchkick searchable: [:name]
  tinkick searchable: [:name]
end

Product.searchkick_search("coffee") # Existing Searchkick backend
Product.tinkick_search("coffee")    # PostgreSQL/TIN backend
```

`tinkick_search` is always explicit. Tinkick installs `search` only if the model
does not already respond to that name, including inherited or nonpublic methods.
Searchkick can install its own alias when declared later, so use the explicit
methods during a transition. Tinkick does not define a `Searchkick` constant,
replace `searchkick`, or share the other gem's configuration.

To choose a different alias, configure it before models declare `tinkick`:

```ruby
# config/initializers/tinkick.rb
Tinkick.search_method_name = :tin_search
# Product.tin_search("coffee") calls Tinkick.
```

Set it to `nil` to create no alias. Existing methods with the chosen name are
preserved, and `tinkick_search` remains available. Changing this setting affects
subsequent declarations; it does not rename aliases already installed on models.

Shared model declaration defaults are also independent of Searchkick:

```ruby
# Set before the affected models declare tinkick.
Tinkick.model_options = {stem: false, match: :word}
```

Explicit model options override these defaults, including `nil`, `false`, and
empty arrays. Defaults pass through the same validation as model declarations;
they do not add database connections during class registration. Replacing the
global defaults hash affects subsequent declarations.

`Tinkick.models` lists the loaded classes that successfully declared `tinkick`,
in declaration order. It is independent of `Searchkick.models`. Subclasses that
inherit a declaration do not add duplicate entries, and inspecting the registry
does not query PostgreSQL or eager-load application models.

Audit the features below before changing callers. Existing Searchkick callbacks,
queues, Redis dependencies, and reindex jobs still belong to Searchkick; retire
them when the old backend is no longer needed. See the
[transition guide](docs/migrating-from-searchkick.md) and
[compatibility inventory](docs/compatibility.md).

## Datasource and migrations

### `search_data` is a schema check

Tinkick calls `search_data` on a **new, unsaved model instance** and checks that
its keys are column names. It never serializes the returned values or copies
them to another index.

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:display_name]

  def search_data
    { display_name: self[:display_name], in_stock: self[:in_stock] }
  end
end
```

Every key must exist, including fields used only for filtering. A value calculated
by Ruby does not override its stored column. A missing column raises an error
instructing you to add a migration. Methods that require a saved ID, an associated
record, or existing rows must be changed to run safely on a new instance.
Without `search_data`, the model's columns supply the field inventory.

### Computed fields and generated columns

For a same-row expression, a stored generated column can replace computed
`search_data` and provide one combined searchable field:

```ruby
class AddDisplayNameToProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :products, :display_name, :virtual,
      type: :text,
      as: "coalesce(name, '') || ' ' || coalesce(description, '')",
      stored: true

    add_index :products, :display_name, using: :tin,
      name: "products_display_name_tin"
  end
end
```

Use an ordinary persisted column when the value needs Ruby logic, associations,
or other rows; your application must maintain that value. PostgreSQL generated
expressions must use immutable functions and cannot contain subqueries or read
other rows. See [generated columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html).

A combined field changes matching semantics: words can match across the original
columns, and phrases can cross their join boundary. Choose that behavior
explicitly instead of treating combination as a transparent index optimization.

### Generator behavior

`tinkick:install` generates extension enablement, not server software installation.
Its rollback refuses to remove a shared extension. Re-running the generator
preserves existing or edited installation migrations.

`tinkick:index TABLE FIELD...` adds separate reversible indexes for existing
columns. It does not create columns, infer Ruby methods, or accept expressions
and schema-qualified names. Duplicate fields and invalid identifiers are rejected.
Review generated migrations through the application's normal deployment process.
For custom names or specialized indexes, write an application Rails migration.
The current model API requires valid, ready, nonpartial, direct-column TIN indexes.

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
available. Boosted names such as `"name^5"` remain implementation work.

`fields: ["*"]` searches declared `searchable` fields, or eligible text columns
when none are declared. Leading `*.` patterns also expand known dotted paths:
`fields: ["*.title"]` includes a declared `metadata.title`. They never discover
arbitrary JSON keys. Partial match patterns expand fields configured for that
mode; exact-mode `"*"` and patterns such as `"na*"` remain literal field names,
matching Searchkick's field handling. An unmatched pattern has no lexical hits.
Per-field misspelling restrictions must use the original selector, for example
`fields: ["*"], misspellings: {fields: ["*"]}`.

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

## Results and metadata

By default, results are actual ActiveRecord model instances selected from the
search query. Tinkick does not fetch external document IDs and then perform a
second database lookup.

```ruby
results = Product.search("apple").limit(20)
results.each { |product| puts product.name }
results.to_a
results[0]
results.first
results.size
results.any?
results.empty?
results.with_score.each { |product, score| puts [product.name, score] }
results.pluck(:id, :name)
```

`size`, `length`, Enumerable `count`, `slice`, and array access describe the loaded
page. Use `total_count` or `total_entries` for the complete filtered result count;
that runs SQL without instantiating every matching record. The count is not capped
at the default 10,000-row retrieval limit.

`pluck` reads only the result page. With model results it uses the loaded models;
with an unloaded `load: false` relation it projects the requested SQL columns
without instantiating models or loading the original relation. Already loaded
pages are reused. `load: false` still logs its compatibility warning.

Available pagination metadata includes `current_page`, `per_page`/`limit_value`,
`padding`, `total_pages`/`num_pages`, `offset_value`/`offset`,
`previous_page`/`prev_page`, `next_page`, `first_page?`, `last_page?`, and
`out_of_range?`. Supplying `total_entries:` overrides the reported total when the
application already knows it; an inaccurate override gives inaccurate page metadata.
`model_name` returns the model's `ActiveModel::Name`; `entry_name` supports Rails
translations, `count:`, and `locale:` for pagination labels without running SQL.

### Legacy raw-row results

```ruby
results = Product.search("apple", load: false)
results = Product.search("apple").load(false)
row = results.first
row.name
row["name"]
```

This returns `Tinkick::HashWrapper` objects over database values and logs a
migration warning. Prefer normal model results. Both modes use PostgreSQL through
ActiveRecord; `load: false` is **not** a performance recommendation or an external
`_source` document. `load` without an argument executes the relation; it is
different from `load(false)`.

`missing_records` returns `[{id: "123", model: Product}]` for records removed by
`scope_results` or deleted between search selection and scoped loading. IDs are
strings, in original page order. Calling it loads and caches that page without
requesting a count or filling its gaps; ordinary and raw results return `[]`.

`took` returns cached integer milliseconds of client elapsed time for resolving
and fetching the bounded page. It includes query compilation, tokenization, and
any required `misspellings: {below: ...}` decision count. It excludes separately
requested totals/aggregations, association preloads, and `scope_results` loading;
it is not a PostgreSQL server-only execution metric. `error` fetches the same page
and returns `nil` on success. Database errors still raise normally. Neither
metadata method adds a total-count query or invokes result scopes/preloads, and
subsequent result loading reuses the page.

### Hits

```ruby
results = Product.search("coffee", select: [:name])
results.hits
results.with_hit.each { |product, hit| puts [product.name, hit["_score"]] }
```

`hits` returns the original bounded search page. Each hash has a string `_id`
from the model's primary key, the PostgreSQL table name as `_index`, and the
native numeric `_score`. `with_hit` pairs those hashes with visible records after
`scope_results`; missing records remain in `hits`. Both methods reuse the page
query and preserve the original hit association when a loaded record is edited.

Model results omit `_source` by default. Use `select: true` or source selectors
to include it; model attributes still load completely. Raw results include
source by default, including with `select: false`. `select: []` omits source in
both modes. Source filters exclude hidden identity/cursor columns unless selected.
An unfiltered source contains physical model columns, including its primary key,
with PostgreSQL/ActiveRecord value types; it never evaluates `search_data` values.
Sources preserve the fetched values when result objects are subsequently edited.

### Response metadata

`response` returns a cached hash with `"took"`, `"hits" => {"hits" => [...]}`,
and `"aggregations"` when requested. Its hits are the same pre-scope page returned
by `hits`; calling it does not invoke `scope_results` or association preloads.
Ordinary pagination also includes `"hits" => {"total" => {"value" => count,
"relation" => "eq"}}`, which requests an exact SQL count. Countless and keyset
responses omit `"total"` unless the application supplies `total_entries:`;
reading their response does not introduce a count query. The supplied total is
reported as given, including with countless pagination. `took` remains the page
fetch timing described above, excluding separate count and aggregation queries.

Suggestions remain implementation work. Aggregation metadata is also available
through `aggs` and `aggregations`. Searchkick 6 removed `each_with_hit` and
`with_details`; use `with_hit.each` and `with_highlights`.
The portable response does not fabricate Elasticsearch index aliases, `_shards`,
scroll IDs, or transport status. Use ActiveRecord instrumentation for timing and
explicitly serialize the visible records for an HTTP response.

## Filtering

Model declarations accept `filterable: [:store_id, "metadata.category"]`.
Tinkick validates the physical columns and JSONB path roots when search is used;
missing columns raise a migration-oriented error. This also works through
`Tinkick.model_options`. `nil`, `false`, and `[]` skip declaration checks.
The declaration does not restrict filters to listed fields or create indexes:
filtering uses the existing PostgreSQL table. Add ordinary B-tree, GIN, or other
appropriate indexes in Rails migrations for the application's actual queries.

Filters use real columns and bound values. These scalar forms are available:

The `id` filter refers to the model's primary key, including custom names and
UUID keys. This also applies when the table has a separate physical `id` column;
use the primary key's actual name for an explicit equivalent filter.

| Operation | Example |
| --- | --- |
| Equality / NULL | `where(store_id: 1)`, `where(deleted_at: nil)` |
| Inequality | `where.not(store_id: 2)` |
| IN / NOT IN | `where(store_id: [1, 2])`, `where.not(store_id: [1, 2])` |
| Explicit IN / NOT | `where(store_id: { in: [1, 2] })`, `where(store_id: { not: 2 })` |
| Comparison | `where(price: { gt: 10, lte: 50 })` |
| Inclusive / exclusive range | `where(price: 10..50)`, `where(price: 10...50)` |
| Open-ended range | `where(created_at: 1.week.ago..)`, `where(price: ..50)` |
| Existence | `where(deleted_at: { exists: false })` |
| LIKE / ILIKE | `where(name: { like: "App%" })`, `where(name: { ilike: "%apple%" })` |
| Literal field prefix | `where(name: { prefix: "Apple" })` |
| Native PostgreSQL regexp | `where(name: { regexp: "^Moria.*$" })` |
| Boolean OR | `where(_or: [{ in_stock: true }, { backordered: true }])` |
| Boolean AND / negation | `where(_and: [{ price: { gt: 10 } }, { price: { lt: 50 } }])`, `where(_not: { store_id: 2 })` |
| Legacy grouped OR | `where(or: [[{ store_id: 1 }, { store_id: 2 }]])` |

Negation includes SQL NULL values where the corresponding positive condition is
not true. `_not` negates each supplied field predicate, following the implemented
Searchkick contract; use explicit `_and`/`_or` grouping for complex expressions.
`exists` tests NULL, not whether a column name exists. Missing columns raise an
error. LIKE `%` and `_` are wildcards; use escaped patterns for literal characters.
Prefix filtering operates on the whole column, not individual search tokens.

For Rails enums, equality, `in`, `all`, and negation use the serialized label.
For example, `status: :published` matches an enum declared as `published: 0`;
`status: 0` looks for a label named `"0"`, not the backing ordinal. Unknown labels
match nothing and do not become NULL comparisons. Known labels use bound backing
values, allowing ordinary column indexes. Duplicate mappings use the first label
returned by Rails when a record is reloaded. A label mapped to SQL NULL counts as
present; an unrecognized stored backing value counts as missing.

Ranges, comparisons, prefix/LIKE/ILIKE, and regexp filters operate on those
canonical labels too. Ranges use byte ordering, so backing ordinal order cannot
change the result. These paths evaluate a SQL `CASE` expression and warn about
their cost; an ordinary backing-column index cannot accelerate that expression.
Use selective filters and inspect the query plan, or add an expression index.

The `all` operator is accepted on scalar columns as a conjunction of equalities;
a scalar cannot equal two distinct values. PostgreSQL array equality means
element membership; `in` accepts any supplied element and `all` requires every
supplied element. These use native containment predicates compatible with GIN.
Ranges require one element to satisfy all bounds. NULL, empty arrays, and arrays
containing only NULL have no searchable value. Pattern and range checks expand
elements and log a performance warning.

JSONB filters accept dotted paths, typed scalar values, recursively nested arrays,
and arrays of objects:

```ruby
Product.search("*", where: { tags: { all: ["fruit", "fresh"] } })
Product.search("*", where: { "metadata.origin" => "local" })
Product.search("*", where: { "metadata.variants.price" => { gte: 10, lt: 50 } })
```

JSONB equality uses a bound JSONPath predicate to find candidates, then verifies
the requested path through all array levels. Only the named object keys advance
the path; a matching value under an unrelated key cannot satisfy the filter.
All range bounds must match the same scalar leaf. Separate conditions on an
object array may match different objects, following flattened Searchkick object
semantics. Use JSONB rather than PostgreSQL's `json` type.

The candidate predicate can use a default `jsonb_ops` GIN index; `jsonb_path_ops`
cannot index its recursive descent. Recursive verification logs a cost warning.
Range, pattern, and missing checks additionally warn that they cannot extract
selective GIN equality keys. Indexed persisted or generated scalar columns are
often better for frequent filters. Missing paths, JSON null, and empty/null-only
arrays or objects match `nil`/`exists: false`. Object containers are present when
any descendant has a non-null scalar value, including `false`, zero, or an empty
string. Equality, range, and pattern checks still use the exact requested path.
See the [recursive JSONB plans](docs/recursive-json-plans.md) for measured
candidate pruning and its limits.

String `regexp` patterns use native PostgreSQL `~` on scalar, PostgreSQL array,
and dotted JSONB text fields:

```ruby
Product.search("coffee", where: { name: { regexp: "(?i)^organic" } })
Product.search("*", where: { "metadata.code" => { regexp: '[[:digit:]]{2}\Z' } })
Product.search("archive", where: { name: { regexp: "^Moria.*$" } })
```

Pattern strings are bound unchanged; use PostgreSQL syntax and embedded flags
such as `(?i)` for case-insensitive matching. Ruby Regexp values raise
`Tinkick::NotImplementedError`; use `regexp: "..."` instead. Tinkick does not
adapt Ruby regex sources or flags. Matching is unanchored unless the pattern
supplies anchors. Use `\A` and PostgreSQL `\Z` for complete-string boundaries;
`^`/`$` newline behavior follows the native flags. PostgreSQL `\b` means
backspace; its word-boundary escape is `\y`.
See [PostgreSQL pattern matching](https://www.postgresql.org/docs/18/functions-matching.html).

Lucene operators such as intersection/complement and decimal intervals are not
emulated. Use SQL boolean filters and native patterns, for example:

```ruby
Product.search("archive", where: {
  _and: [{ name: { regexp: "Moria" } }, { _not: { name: { regexp: "closed" } } }]
})
Product.search("*", where: { "metadata.code" => { regexp: "^room(0[1-9]|1[0-2])$" } })
```

Each array or JSONB pattern matches one string element. Separate boolean filters
retain the array/path semantics described above. JSONB numbers, booleans, and
null are not converted to text; canonical enum labels are supported. Invalid
native patterns raise a PostgreSQL error through `ActiveRecord::StatementInvalid`.
Regex filters log a scan warning. Use selective TIN/SQL conditions and inspect
`EXPLAIN`; optional `pg_trgm` indexes may help suitable patterns. No extension is
required for matching. Geospatial filter hashes remain implementation work.

Recipe alternatives, returning ordinary ActiveRecord relations:

```ruby
Product.where("tags @> ARRAY[?]::text[]", ["fruit", "fresh"])
Product.where("metadata @> ?::jsonb", { origin: "local" }.to_json)
Product.where("name ~ ?", "^Apple [[:alpha:]]+$")
```

These require the shown column types and appropriate indexes. Check pattern
syntax against PostgreSQL when migrating from Ruby or Lucene.

## Matching and analysis

### Whole words, operators, and phrases

```ruby
Product.search("red apple", misspellings: false)                 # Both words
Product.search("red pear", operator: "or", misspellings: false) # Either word
Product.search("red apple", match: :phrase)                     # Adjacent, ordered
```

With several fields, the current query requires all AND terms to match within
one field. A word in `name` and another only in `description` do not together
satisfy the query. `:phrase` applies no fuzzy edits. Phrase punctuation is escaped
as literal user input; underscores do not become positional wildcards.

### Misspellings

Public searches use native TIN Levenshtein distance one and prefix length zero:

```ruby
Product.search("appl")
Product.search("appl").misspellings(false)
Product.search("appl", misspellings: { prefix_length: 2 })
Product.search("appl", misspellings: { edit_distance: 0 })
Product.search("aplpe", misspellings: { edit_distance: 2, transpositions: false })
Product.search("mithrl", fields: [:name, :description],
  misspellings: { fields: [:name], prefix_length: 2 })
```

`distance` is an alias for `edit_distance`. Native TIN edits handle insertion,
deletion, and substitution. An adjacent swap needs two native edits.
The prefix protects the specified number of Unicode codepoints. Options must
use nonnegative integer distances and prefixes.

`misspellings: {fields: [...]}` enables fuzzy matching only on those selected
fields. Other searched fields still match exactly; `fields: []` disables
fuzziness on every field. Names must belong to the search's selected fields,
including any dotted JSON paths. This also works through `.misspellings(...)`.
Exact and phrase modes remain exact. Partial token and whole-field modes require
`misspellings: false` or `edit_distance: 0`.

The default deliberately uses **uncapped native expansion**, rather than
Searchkick's implicit three expansions. It may return additional valid typo
matches. This choice favors TIN performance; numerical scores and tied ordering
are also allowed to differ. Explicit controls must not be silently ignored.

When fuzzy matching is used, `max_expansions` and `transpositions: true` raise
`Tinkick::NotImplementedError`: TIN does not provide those Elasticsearch fuzzy
controls. `transpositions: false` accepts native Levenshtein behavior. Tinkick
does not install a custom edit-distance function or generate fuzzy alternatives.
Phrase and exact modes ignore unused misspelling settings.

Native fuzzy terms cannot contain TINQL delimiters such as parentheses, brackets,
quotes, tildes, or carets. If a custom tokenizer retains these characters in a
token, use `misspellings: false`; a fuzzy request raises a clear error.

Use `below` to enable fuzzy matching only when the exact filtered search has
fewer than the requested number of matches:

```ruby
results = Product.search(user_text, misspellings: {below: 5}, limit: 20)
results.misspellings? # whether the fuzzy pass was enabled
```

The adapter runs one exact-match count capped at the threshold, logs an extra
query warning, and reuses that decision for records, totals, and aggregations.
It counts the original filters and exclusions, independently of pagination,
`scope_results`, and `total_entries`. Numeric strings and floats use Searchkick's
integer conversion; zero or negative thresholds keep exact matching, while nil
or false disables the threshold. There is no retry expansion cap or added
database snapshot. `misspellings?` describes the selected pass, so it can be true
for exact/phrase modes or `fields: []`; a plain match-all search returns false.
Explicit expansion caps are an unsupported Elasticsearch control; use native
uncapped matching or retain the old search path when that cap is required.

Literal keycap emoji such as `*️⃣` and `#️⃣` support literal and distance-one
fuzzy matching without interpreting their analyzed punctuation as match-all. See the
[TINQL fuzzy syntax](https://planetscale.com/docs/postgres/search/tinql) and
[compiler integration tests](test/integration/query_text_test.rb).

### Partial and exact field matching

| Searchkick mode | Current Tinkick status | Implementation |
| --- | --- | --- |
| `:word` | Available | Disable misspellings for exact token matching. |
| `:phrase` | Available | Ordered adjacent tokens. |
| `:word_start`, `:word_middle`, `:word_end` | Available without misspellings | Native token wildcards. |
| `:text_start`, `:text_middle`, `:text_end` | Available without misspellings | Whole-field PostgreSQL `LIKE`; requires `unaccent` for accent folding. |
| `:exact` | Available globally and per field | Case-sensitive, accent-sensitive whole-field SQL equality; ignores misspellings. |
| Mixed per-field match modes | Available | Each field keeps its own mode; SQL/TIN branches are combined and deduplicated in PostgreSQL. |

Declare Tinkick and choose match modes per query:

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:name, :description], word_start: [:name]
end

Product.search("app", fields: [:name], match: :word_start, misspellings: false)
Product.search("fresh orchard", fields: [:description], match: :text_start, misspellings: false)
Product.search("Red Apple", fields: [{ name: :exact }, { description: :phrase }])
```

Token modes use existing TIN indexes; separate ngram indexes are unnecessary.
Partial model declarations are accepted without opening a database connection.
Whole-field modes preserve whitespace and fold case/accents with PostgreSQL
`unaccent`; the extension is needed only when such a query executes. They use
SQL scans and log a warning. Native wildcard and `LIKE` matching do not impose
Searchkick's 50-character ngram limit.

SQL-only matching returns constant scores and needs no TIN index on those fields.
Mixed SQL/TIN matching adds native TIN scores and SQL-match scores, then groups
record IDs before pagination. It logs a warning because grouping/sorting can cost
more than native top-k search. Fuzzy wildcard and whole-field substring matching
have no corresponding native TIN primitive and raise `Tinkick::NotImplementedError`.
Use `misspellings: false` for these modes, or `match: :word` for native fuzzy search.

### Case, accents, whitespace, and emoji

With default index settings, TIN uses Unicode analysis. Case and accents fold,
so `JALAPEÑO` can match `jalapeno`; hyphens can split words, while underscores and
apostrophes can remain within tokens. Emoji can be indexed as tokens. This does
not provide Searchkick's emoji-to-name expansion: `🍰` is not automatically
translated to `cake`. The `emoji` option is not implemented; an application can
normalize both stored search text and query text with a chosen emoji dictionary.

Searchkick's extra-whitespace/word-joining analyzers are not reproduced:
`dishwasher` and `dish washer` need not have the same matches. Persist an
application-normalized search column if that behavior is required.

Declare case and accent behavior on the model:

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:name], case_sensitive: true, special_characters: false
end
```

`case_sensitive: true` requires the TIN index's `case_folding = 'preserve'`;
false or nil requires `'fold'`. `special_characters: false` requires
`accent_folding = 'preserve'`; true or nil requires `'fold'`. This option controls
accent folding, not punctuation tokenization. Mismatched declarations raise
instructions to rebuild the affected index through a Rails migration. Model
declarations never change indexes automatically.

Omitted options adopt the native index's existing policy. Explicit nil requests
the folded default, including when overriding `Tinkick.model_options`. SQL
`text_start`, `text_middle`, and `text_end` apply the declared controls to both
query and stored text; their omitted defaults fold case and accents. These SQL
modes need `unaccent` only when accent folding is enabled. `match: :exact` keeps
its byte-sensitive behavior. Fuzzy searches can still match case/accent
differences as edits. Unicode normalization is not identical across all engines.

Custom Elasticsearch analyzer mappings are not accepted. Native literal, phrase,
and partial queries read the selected
index's actual analysis settings, including preserved case/accents and whitespace
tokenization. Each selected field uses its own configuration. Fuzzy queries use
native term syntax; tokens containing unsupported TINQL delimiters require
exact matching instead. Index metadata is cached per model
and connection pool; after rebuilding an index with changed tokenization, call
`Product.reset_column_information` or restart application processes to refresh
it. Multiple indexes for the same source must agree on analysis.
See [TIN index options](https://planetscale.com/docs/postgres/search/reference/indexes).

### Stemming and language

**Native difference:** TIN explicitly documents no stemming. Searchkick's English
stemming, `language`, `stem`, Hunspell dictionaries, `stem_exclusion`, and
`stemmer_override` therefore have no current Tinkick equivalent.
Requesting `stem: true`, `language`, `stemmer`, `stem_exclusion`, or
`stemmer_override` raises `Tinkick::NotImplementedError`, explaining that stemming
is not yet supported by TIN and how to migrate. `stem: false` is accepted and
uses native token matching. The exception inherits from `Tinkick::Error` and
`StandardError`, so ordinary application error handling can rescue it.
Fuzzy matching a plural is not the same thing as stemming it.
See the [TIN capability comparison](https://planetscale.com/docs/postgres/search).

Recipe alternatives include application-maintained normalized text, or a separate
PostgreSQL `tsvector`/`tsquery` search using an appropriate language configuration.
That is a different analysis/ranking path, not a TIN compatibility switch.
Language-specific Searchkick plugins for Chinese, Japanese, Korean, Polish,
Ukrainian, or Vietnamese cannot be loaded into Tinkick. Choose and test the
normalizer/tokenizer needed for the application's language. PostgreSQL documents
[its own dictionaries and stemming pipeline](https://www.postgresql.org/docs/current/textsearch-intro.html).

### Synonyms, exclusions, and bad matches

Static, directional, multiword, and dynamic `search_synonyms`, synonym files,
and `reload_synonyms` are not implemented. Possible application designs include
normalized stored values and controlled query expansion from a synonym table.
Keep multiword phrase meaning and one-way mappings explicit. No TIN-native
impossibility is implied by the missing adapter.

`exclude` removes exact phrases from every selected search field:

```ruby
Product.search("butter", exclude: "peanut butter")
Product.search("butter").exclude("peanut butter").exclude("almond butter")
```

Exclusions do not use typo matching. Phrase order and adjacency matter; partial
word modes exclude adjacent partial-token phrases, while text and exact modes
use their whole-field matching rules. Tinkick escapes literal input and follows
the indexed field's tokenizer options. A single native field combines the
negative phrase in the TIN query and retains top-k ranking. Multi-field,
and match-all paths use matching-ID subqueries to preserve
NULL/missing fields and log their additional cost. Use `boost_where` with a
fractional factor to demote matching records without excluding them.

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

Token autocomplete is available through `word_start` and ordinary bounded results:

```ruby
Movie.search("jurassic pa", fields: [:title], match: :word_start,
  misspellings: false, limit: 10).pluck(:title)
```

Tinkick escapes user text when compiling this query. A Rails JSON endpoint can
return the bounded page; debounce requests and cap returned rows. Alternatively,
use the scalar `prefix` filter for a whole-column prefix, understanding that its
semantics differ from token autocomplete. Do not load an entire table solely to
populate an autocomplete widget.

“Did you mean” needs candidate generation and phrase/ranking rules; returning fuzzy
hits is not a compatible `suggestions` implementation. Autosuggest and client UI
libraries can be integrated independently, but are not bundled or verified here.
`load: false` does not provide the Searchkick external-document optimization.

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
| Terms | `field`, `limit` (default 1,000), `min_doc_count` (default 1), and `_key`/`_count` ordering |
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

`min_doc_count: 0` reads the model's scoped dictionary so unmatched values can
produce zero-count buckets. It logs a warning because broad dictionaries cost
more. Array aggregation and exact `COUNT(DISTINCT)` cardinality also warn about
workload-dependent cost. Aggregations group and sort in PostgreSQL; terms also
apply their bucket limit there. They do not group Ruby model records.

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
histogram. Numeric formatting remains adapter work.

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

Nested aggregations and additional aggregate options remain adapter
implementation work. Elasticsearch/Painless scripts are not SQL;
use a reviewed persisted/generated column or an explicit application SQL query
for scripted calculations. Check representative plans against TIN's
[SQL shape guidance](https://planetscale.com/docs/postgres/search/reference/sql-shapes).

## Highlighting

Default-analysis word, phrase, and partial-word searches support highlighting:

```ruby
results = Product.search("rivendell", fields: [:name], highlight: true)
results.highlights                  # [{name: "Visit <em>Rivendell</em>"}]
results.with_highlights.each { |product, spans| puts spans[:name] }
results.first.search_highlights

results = Product.search("rivendell").highlight(
  tag: "<strong class='match'>", encoder: "html",
  fields: {name: {fragment_size: 100, number_of_fragments: 3}}
)
results.highlights(multiple: true)   # each field maps to an array of snippets
```

Without a fragment size, the complete matched field is returned. Positive sizes
produce up to five distinct snippets by default, preserving complete Unicode
graphemes and matched spans; a long word or phrase may exceed the requested size.
Per-field options override global options. `number_of_fragments: 0` returns the
complete field. Context boundaries approximate Searchkick rather than reproducing
Lucene's fragment ranking. A fields array also works, such as `fields: [:name]`.

`highlights` follows the original hit page; `with_highlights` follows visible
records after `scope_results`. Their default field values are the first snippet;
`multiple: true` returns arrays. Hit metadata stores arrays under `"highlight"`.
Raw results have `highlighted_name`-style keys, falling back to the selected
original value when no span matches. Match-all queries have empty highlight maps.
Existing model `search_highlights` methods are preserved for backend coexistence.

Highlighting batches the bounded page in one native call per field and caches the
result. Native TIN identifies the matched spans, including native fuzzy matches.
Highlighting does not count matches or alter search ranking. Raw projections fetch
only selected columns plus required highlight inputs; hidden inputs stay out of
the source and raw result attributes. Large pages or long fields increase transfer
and presentation work, so set a suitable page limit.

`:exact`, `:text_start`, `:text_middle`, and `:text_end` also support highlights.
They mark the complete matching field, reflecting Searchkick's whole-field
analysis. A small fragment size does not split that complete match span. Each
SQL field is checked against the same search predicate in a bound page batch,
so a record matching another field does not create a false highlight. These SQL
modes require `misspellings: false`; fuzzy whole-field matching is unavailable.

Native highlighting preserves document HTML. `encoder: "html"` escapes source
text separately from trusted highlight tags; returned strings are not marked
HTML-safe. Do not mark untrusted native output `html_safe`.

Lexical highlighting with non-default index tokenization raises
`Tinkick::NotImplementedError`. This includes custom case/accent settings,
whitespace tokenization, token-length policies, and grapheme policies. Native
implicit `tin.highlight(indexed_column)` rejects non-default tokenization, while
the explicit-query form uses default analysis. Tinkick does not reconstruct token
positions or silently highlight using a different analyzer. Query matching remains
available; omit highlighting for that field, select a default-analysis field in
`highlight: {fields: [...]}`, or use SQL whole-field matching where appropriate.
See [TIN highlighting](https://planetscale.com/docs/postgres/search/highlighting).

Model declarations such as `tinkick searchable: [:name], highlight: [:name]` are
accepted. Declared highlight fields are checked when the model is searched, with
a migration error for missing columns. The declaration does not enable query
highlighting or limit which queried fields can be highlighted: pass `highlight:`
to the search as shown above. TIN needs no separate term-vector storage for this
declaration. See
[TIN highlighting](https://planetscale.com/docs/postgres/search/highlighting).

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
not TINQL. RRF or model-based reranking requires explicit application code and
returns an application-defined result list.

## Pagination and large result sets

### Page and offset compatibility

```ruby
results = Product.search("apple").page(2).per_page(20)
results = Product.search("apple", page: 2, per_page: 20, padding: 3)
results = Product.search("apple").limit(20).offset(40)
```

`per` aliases `per_page`. `limit` takes precedence over `per_page`; an explicit
`offset` takes precedence over calculated page/padding offsets for retrieval.
Regular `next_page`/`total_pages` use the total count. The basic metadata is
implemented, but Kaminari and will_paginate view helpers have not been verified
as complete integrations; do not assume every helper-specific method exists.

Nonzero offsets can bypass TIN's top-k plan and sort matching rows. Tinkick logs
a warning when fetching such a ranked page. Deep paging is not protected by
Elasticsearch's 10,000-result window; the default limit is a retrieval default,
not an invitation to scan arbitrarily large pages.

### Countless pagination: opt in

```ruby
page = Product.search("apple", limit: 20, countless: true)
page.to_a
page.has_next_page?
page.next_page
```

Or call `.countless` on an unloaded relation. This fetches at most one extra row
to answer whether another page exists, without an automatic count. Relevance
ordering remains available. Calling `total_count` or `total_pages` still explicitly
requests the count. Countless pagination does not remove offset costs on later
numbered pages. A positive limit is required.

### Keyset pagination: opt in

```ruby
first = Product.search("apple", order: { id: :asc }, limit: 20, keyset: true)
cursor = first.next_cursor
second = Product.search("apple", order: { id: :asc }, limit: 20,
  keyset: true, after: cursor) if cursor
```

The fluent equivalent is `.keyset(after: cursor)`. Keyset pagination uses stable
column order rather than relevance and implies countless behavior. With no order,
it uses the primary key ascending; otherwise it appends the single primary key
as a tiebreaker unless already present. Use `has_next_page?` and `next_cursor`,
not `next_page`. Do not request another page when the cursor is nil.

Order columns must be nonnullable supported scalars: integer, text/citext/string,
UUID, date, timestamp, or decimal. Nullable columns, score ordering, repeated
columns, composite primary keys, offset, page greater than one, and padding are
rejected. Add appropriate ordinary indexes for the chosen order; arbitrary
column sorts are not promised TIN top-k performance.

Integer-backed Rails enum columns use their stored integer order and cursor
values. Both model and raw results retain the enum labels; projecting the enum
out of raw results still preserves its hidden cursor value.

A cursor is an encoded position, not a signature, authorization token, or
snapshot. Reapply the same query, order, filters, and tenant restrictions on every
request. Concurrent changes to sort values can affect traversal. Explicit totals
count the full filtered search, not just rows after the cursor.

### Scroll and exports

Searchkick's `scroll`, `scroll_id`, and `clear_scroll` are excluded backend cursor
APIs. For application exports, use a bounded keyset loop, or build an ordinary
ActiveRecord SQL scope and use [Rails batch APIs](https://api.rubyonrails.org/classes/ActiveRecord/Batches.html).
Batches do not preserve relevance order or create a stable snapshot automatically.
`deep_paging` and `body_options(track_total_hits: true)` are not required for an
explicit SQL total, and are not accepted Tinkick options.

## Models, scopes, and tenancy

### Default scopes, associations, and inheritance

Search queries start from the model's ActiveRecord scope, including default
scopes. Registration is inherited by subclasses. Searchkick's `inheritance:` and
query `type` options are not implemented; STI-specific behavior still needs its
own compatibility coverage rather than an assertion that all inheritance cases
are equivalent.

Call search on the model, not an ActiveRecord relation or association:

```ruby
Product.search("apple", where: { store_id: store.id })
```

`store.products.search(...)` and `Product.where(...).search(...)` are rejected.
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
[filtering](#filtering). Text search also accepts dotted scalar paths:

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

`search_data` continues to validate physical column names: return the `metadata`
column key, not dotted virtual keys. Use persisted or generated text columns when
you need custom normalization or a combined document. Flattened array-of-object
filters do not preserve same-object correlation; use explicit `EXISTS`/joins or
JSON predicates when that distinction matters.

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

**Multi-field compatibility cost:** on the tested TIN 1.0.2 endpoint, a particular
multi-index plan returned no scored rows despite a positive match count. Tinkick
uses full scoring for multi-field retrieval to preserve those matches, and logs
its extra scoring/sort cost. This is an observed endpoint/plan issue, not a claim
that TIN lacks multi-field search. A stored or generated combined column can
provide a single-index path if its matching semantics fit the application.

Explicit boosts, full scoring, custom SQL ranking, multiple fields, and offset
pagination can cost more than the native single-field top-k shape. Log warnings
identify native SQL paths with known costs. Native fuzzy matching
also adds work; uncapped defaults avoid a separate
candidate-enumeration pipeline but are not free. Disable misspellings when the
product requires exact lexical matching.

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
and never substitutes a different search engine. Separate fixture processes must
not run concurrently against this shared test database.

CI serializes the Rails matrix and requires the configured test database secrets
(`PGHOST`, `PGUSER`, `PGPASSWORD`, with optional `PGPORT`/`PGSSLMODE`). It does not
install a pretend local TIN extension or run Elasticsearch setup actions. See
[the workflow](.github/workflows/ci.yml); a configured matrix is not a claim that a
remote CI run has completed.

## Reference and unsupported options

The current model declaration accepts `searchable`, `default_fields`, `match`,
the `word_start`/`word_middle`/`word_end` and `text_start`/`text_middle`/`text_end`
field declarations, and `stem: false`.
It also accepts `conversions`/`conversions_v1`, `conversions_v2`, and
`stem_conversions: false` for native JSONB conversion ranking.
The public search accepts `fields`, `where`, `order`, `limit`, `offset`, `page`,
`per_page`, `padding`, `match`, `operator`, `misspellings`, `load`, `total_entries`,
`countless`, `keyset`, `after`, `aggs`, `smart_aggs`, `includes`,
`model_includes`, `scope_results`, `exclude`, `select`, `highlight`,
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
| `body`, `body_options`, query-mutating blocks | Excluded Elasticsearch DSL; use reviewed native SQL. |
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
