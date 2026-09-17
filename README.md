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
including features that still need an adapter or a different application design.

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
bin/rails generate tinkick:install --unaccent --fuzzystrmatch --pg-trgm
```

The default generator enables only TIN. Optional extensions are checked when a
feature uses them; they do not block loading the gem or ordinary TIN searches.
A missing dependency raises `Tinkick::Error` with the required `enable_extension`
Rails migration. If an installation migration already exists, add a new
application migration rather than replacing that migration.

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
| Boolean OR | `where(_or: [{ in_stock: true }, { backordered: true }])` |
| Boolean AND / negation | `where(_and: [{ price: { gt: 10 } }, { price: { lt: 50 } }])`, `where(_not: { store_id: 2 })` |
| Legacy grouped OR | `where(or: [[{ store_id: 1 }, { store_id: 2 }]])` |

Negation includes SQL NULL values where the corresponding positive condition is
not true. `_not` negates each supplied field predicate, following the implemented
Searchkick contract; use explicit `_and`/`_or` grouping for complex expressions.
`exists` tests NULL, not whether a column name exists. Missing columns raise an
error. LIKE `%` and `_` are wildcards; use escaped patterns for literal characters.
Prefix filtering operates on the whole column, not individual search tokens.

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

Ruby Regexp values work on scalar, PostgreSQL array, and dotted JSONB text fields:

```ruby
Product.search("coffee", where: { name: /\Aorganic/i })
Product.search("*", where: { "metadata.code" => /\d{2}\z/ })
```

These preserve Searchkick's Lucene pattern rules: matching is unanchored unless
the source uses `\A`/`\z`; `^`/`$` are literal characters. The `i` flag folds
ASCII literal characters, but does not fold character ranges or accented letters.
Other Ruby options do not change matching. Unsupported Lucene escapes such as
`\b` raise `InvalidQueryError`. Patterns are bound SQL values. This path logs a
scan warning; an optional `pg_trgm` expression index may help suitable patterns,
but is not required. The raw string `regexp` operator and geospatial filter
hashes remain implementation work.

Recipe alternatives, returning ordinary ActiveRecord relations:

```ruby
Product.where("tags @> ARRAY[?]::text[]", ["fruit", "fresh"])
Product.where("metadata @> ?::jsonb", { origin: "local" }.to_json)
Product.where("name ~ ?", "^Apple [[:alpha:]]+$")
```

These require the shown column types and appropriate indexes. PostgreSQL regex
syntax is not Ruby regex syntax; translate and test patterns rather than passing
arbitrary Ruby regex objects through. See [PostgreSQL pattern matching](https://www.postgresql.org/docs/current/functions-matching.html).

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

Public searches default to distance one, prefix length zero, with adjacent
transpositions enabled:

```ruby
Product.search("aplpe")
Product.search("appl").misspellings(false)
Product.search("aplpe", misspellings: { prefix_length: 2 })
Product.search("appl", misspellings: { edit_distance: 0 })
Product.search("aplpe", misspellings: { edit_distance: 2, transpositions: false })
Product.search("mithrl", fields: [:name, :description],
  misspellings: { fields: [:name], prefix_length: 2 })
```

`distance` is an alias for `edit_distance`. Native TIN edits handle insertion,
deletion, and substitution; Tinkick adds exact adjacent swaps for distance one.
The prefix protects the specified number of Unicode codepoints. Options must
use nonnegative integer distances and prefixes.

`misspellings: {fields: [...]}` enables fuzzy matching only on those selected
fields. Other searched fields still match exactly; `fields: []` disables
fuzziness on every field. Names must belong to the search's selected fields,
including any dotted JSON paths. This also works through `.misspellings(...)`,
with partial token and whole-field modes. Exact and phrase modes remain exact.

The default deliberately uses **uncapped native expansion**, rather than
Searchkick's implicit three expansions. It may return additional valid typo
matches. This choice favors TIN performance; numerical scores and tied ordering
are also allowed to differ. Explicit controls must not be silently ignored.

`max_expansions`, including an explicitly requested value of three, remains
adapter work and currently raises.

Whole-word `edit_distance: 2` with transpositions uses native TIN candidates plus
bounded SQL verification. Install its optional helper only if this feature is
needed:

```sh
bin/rails generate tinkick:functions
bin/rails db:migrate
```

```ruby
Product.search("paelp", misspellings: {edit_distance: 2})
```

The helper checks the actual index tokenization settings, preserves fixed
prefixes, and avoids constructing exponentially large regexes for long words.
It logs a warning because token verification can bypass native top-k ranking;
broad candidates and long text can increase cost. Scores come from the native
candidate query and can differ from Searchkick. Normal distance-one search and
gem loading do not require this helper. A missing helper raises migration
guidance only when the corresponding feature is used.

Tokens containing literal TINQL delimiters use escaped token patterns for short
one-edit searches. Longer analyzed tokens, or larger nontransposition distances,
use indexed TIN candidates followed by bounded SQL verification and a cost
warning. This path requires `tinkick.edit_distance`; install the optional
functions migration or generate its `--upgrade` migration for an existing
installation. The decision uses analyzed Unicode length, since case folding can
expand a token. Ordinary native queries keep their existing fast path.

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
There is not yet a verified public replacement for an explicit expansion cap;
retain the old search path if that cap is required for match eligibility.

Literal keycap emoji such as `*️⃣` and `#️⃣` support literal and distance-one
fuzzy matching without interpreting their analyzed punctuation as match-all. See the
[TINQL fuzzy syntax](https://planetscale.com/docs/postgres/search/tinql) and
[compiler integration tests](test/integration/query_text_test.rb).

### Partial and exact field matching

| Searchkick mode | Current Tinkick status | Implementation |
| --- | --- | --- |
| `:word` | Available | Disable misspellings for exact token matching. |
| `:phrase` | Available | Ordered adjacent tokens. |
| `:word_start`, `:word_middle`, `:word_end` | Available | Native token wildcards; dictionary patterns for one edit; SQL refinement for two edits. |
| `:text_start`, `:text_middle`, `:text_end` | Available | Whole-field SQL matching; requires `unaccent` when used. Supports zero, one, or two edits. |
| `:exact` | Available globally and per field | Case-sensitive, accent-sensitive whole-field SQL equality; ignores misspellings. |
| Mixed per-field match modes | Available | Each field keeps its own mode; SQL/TIN branches are combined and deduplicated in PostgreSQL. |

Declare Tinkick and choose match modes per query:

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:name, :description], word_start: [:name]
end

Product.search("app", fields: [:name], match: :word_start, misspellings: false)
Product.search("fresh orchard", fields: [:description], match: :text_start)
Product.search("Red Apple", fields: [{ name: :exact }, { description: :phrase }])
```

Token modes use existing TIN indexes; separate ngram indexes are unnecessary.
Partial model declarations are accepted without opening a database connection.
Whole-field modes preserve whitespace and fold case/accents with PostgreSQL
`unaccent`; the extension is needed only when such a query executes. They use
SQL scans and log a warning. Partial matches retain Searchkick's 1–50 character
gram range; exact whole-field equality has no gram-length restriction.

SQL-only matching returns constant scores and needs no TIN index on those fields.
Mixed SQL/TIN matching adds native TIN scores and SQL-match scores, then groups
record IDs before pagination. It logs a warning because grouping/sorting can cost
more than native top-k search. Fuzzy token partial matching also warns about
dictionary expansion. Use `misspellings: false` when typo matching is unnecessary.

Two-edit token partial matching enumerates bounded grams from native TIN
candidates. It warns because broad candidates and middle-position enumeration
can be expensive and bypass native top-k ranking. A fixed `prefix_length` can
reduce candidates. This path needs the optional SQL helper for transpositions,
or `fuzzystrmatch` when `transpositions: false`; ordinary token searches do not.

Two-edit whole-field queries enumerate candidate substrings in PostgreSQL and log
an additional warning. With transpositions they need the optional SQL helper:

```sh
bin/rails generate tinkick:functions
bin/rails db:migrate
```

With `transpositions: false`, install `fuzzystrmatch` instead. These dependencies
are checked only for the paths that use them; basic search, exact matching, and
one-edit native token matching do not require them. The helper migration installs
`tinkick.osa_distance` and `tinkick.edit_distance` and leaves extensions untouched.
The latter supports bounded Unicode edit distance with optional transpositions,
including tokens beyond `fuzzystrmatch`'s 255-character limit. Neither helper is
required at gem load or model registration. To add it to an existing helper
installation without changing the original migration:

```sh
bin/rails generate tinkick:functions --upgrade
bin/rails db:migrate
```

The upgrade migration adds only `tinkick.edit_distance`; rolling it back preserves
`tinkick.osa_distance` and ordinary TIN search.

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
tokenization. Each selected field uses its own configuration. One-edit fuzzy
queries also escape short preserved punctuation tokens through native dictionary
patterns; longer delimiter tokens and larger edit distances still need SQL
refinement. Index metadata is cached per model
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
match-all, and refined fuzzy paths use matching-ID subqueries to preserve
NULL/missing fields and log their additional cost. Use `boost_where` with a
fractional factor to demote matching records without excluding them.

## Boosting, conversions, and personalization

Native word, phrase, and partial-word fields accept caret weights:

```ruby
Product.search("coffee", fields: ["name^10", :description])
Product.search("coffee").fields({"name^2.5" => :word_start}, :description)
```

Weights from zero through 10,000 use native TIN boosts. Zero preserves matching
rows while suppressing that field's score. `default_fields` and wildcard selectors
also accept weights. Repeated selectors use the last explicit weight for that
selector and match mode; an unweighted duplicate does not reset it. Per-field
`misspellings: {fields: [...]}` uses names without caret weights.

Explicit `^1` pins terms that TIN might otherwise omit from scoring as too common,
so it can change scores even with a factor of one. Native single-field queries
retain the top-k path; existing multi-field/refinement cost warnings still apply.
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
applying the factor and modifier; empty/all-NULL arrays are missing. Each combined
group is capped at the single-precision maximum, including reciprocal zero.
Invalid arithmetic and negative/NaN function scores raise a database error.

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

The shorthand weight is 1,000. Explicit factors accept nonnegative numbers or
numeric strings; factors between zero and one demote matching records. All
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

Date scales and offsets use integer `nanos`, `micros`, `ms`, `s`, `m`, `h` or `d`
units. Submillisecond durations truncate to milliseconds; the resulting scale
must be positive. Bare nonzero numeric date durations, fractional durations,
weeks and months are rejected, following the Elasticsearch time-value parser.
Origins accept dates, times, epoch milliseconds and supported date math such as
`"now-1d"`. Date scoring uses millisecond precision. Numeric columns also accept
these functions with explicit numeric `origin` and `scale`. JSONB recency paths
still require a date/numeric type contract; use a typed stored or generated
column in the meantime.

Recency scoring needs no optional extension. It logs the additional per-row
calculation and sorting cost; counts and aggregation membership remain unchanged.
`nil`, `false` and `{}` disable the option. A single zero-weight recency function
zeros scores; multiple functions whose applicable weights are all zero retain
the original score, matching the upstream sum-group behavior.

`boost_by_distance`, `indices_boost`, and `conversions`/`conversions_v2` remain
adapter work.

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

### Tracking and performant conversions

`track`, Searchjoy integration, conversion-field selection, a separate conversion
query term, and `stem_conversions` are not implemented. You can record query and
conversion events in application tables, aggregate them with SQL, and maintain a
numeric or JSONB feature column through your own job. Updating such a column
needs no search-document reindex. Caching a derived feature can avoid computing
association aggregates per result, but the aggregation, update schedule, and
ranking formula remain application responsibilities.

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
# Category buckets now use the complete record filter.
```

The fluent `.smart_aggs(false)` modifier is equivalent. Smart facet removal only
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
toward zero); UTC is the
default. Output strings include milliseconds and the selected zone. Explicit
input offsets and epoch values preserve their instant.

```ruby
Product.search("coffee", aggs: {
  created_at: {
    date_ranges: [{from: "now-7d/d", to: "now/d"}],
    time_zone: "America/Vancouver"
  }
})
```

Date math uses `now` or an ISO date followed by `||` as its anchor. Add/subtract
`y`, `M`, `w`, `d`, `h`/`H`, `m`, or `s`; round down with `/unit`. Weeks start on
Monday. Calendar-day arithmetic follows DST; adding 24 hours advances exactly
24 elapsed hours. One captured `now` is shared across an aggregation evaluator.

Date ranges also accept `format:`. The default is
`strict_date_optional_time||epoch_millis`; alternatives separated by `||` are
tried in order, and the first format renders bucket keys and bound strings.
Custom formats support `yyyy`/`uuuu`, `MM`, `dd`, `HH`, `mm`, `ss`, `S`/`SS`/`SSS`,
`XXX` offsets, punctuation, and quoted literals:

```ruby
Product.search("coffee", aggs: {
  created_at: {
    format: "yyyy/MM/dd||epoch_millis",
    date_ranges: [{from: "2026/01/01", to: "2026/02/01"}]
  }
})
```

Numeric bounds are truncated and passed through the configured formatter. With
the default formatter, `2026` is a year; explicitly use `format: "epoch_millis"`
when small numbers must mean milliseconds. Missing custom date components use
1970-01-01 and midnight. Locale names, week/era tokens, optional pattern sections,
and fractions beyond three custom digits remain adapter work.

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
`"+01:30"`, `"-05:00"`, or numeric `-5`, inside `date_histogram:`. Buckets round
on that local time grid; `key` remains UTC epoch milliseconds and
`key_as_string` displays the local boundary. Calendar gaps advance in local
calendar time, preserving month starts across February. Offsets may include
seconds, though the upstream-compatible default label prints only offset hours
and minutes. Fixed offsets are limited to ±18 hours. IANA zones such as
`"America/New_York"` work with calendar and fixed intervals. Local days can span 23
or 25 hours. Repeated midnights use the earliest instant; missing midnights use
the first valid instant. Entirely skipped dates do not produce duplicate buckets.
Hour buckets preserve both occurrences of a repeated hour with distinct UTC
keys and offset-bearing labels. Half-hour transitions, such as Lord Howe's,
follow the changed local grid instead of assuming every day has 24 hour buckets.

PostgreSQL groups matching records and generates empty buckets without loading
models. Subday intervals use PostgreSQL's timezone data for both keys and labels;
historical boundaries can differ from Elasticsearch when the installed timezone
databases differ. Explicit subday bounds add one query to round four scalar
endpoints; unbounded histograms need no bounds query. Dense subday ranges use
recursive SQL and can be expensive: prefer `min_doc_count: 1` when empty buckets
are unnecessary.

IANA fixed intervals use the local epoch grid within each UTC-offset period.
Repeated local boundaries retain distinct UTC keys; a forward clock jump can
create a bucket at the transition instant. For example, a `"90m"` grid can
contain both occurrences of `01:30` when New York clocks fall back. Records,
explicit bounds and empty buckets use the same SQL rounding rules.

The fixed-interval path discovers PostgreSQL offset transitions using daily
samples and a binary search within changed days. This relies on the audited
IANA 1850–2050 data having no two transitions within one UTC day (the smallest
observed separation was 601,200 seconds); the lookback also allows two days for
the observed offset range. Wide matching or bound ranges increase discovery
work and log a warning. Apply selective date filters and avoid dense empty
grids when they are unnecessary. No optional extension is needed.

The [measured IANA fixed-interval plans](docs/iana-fixed-plans.md) include the
SQL, binds, rollback-only Tolkien dataset and reproduction command. With 1,000
matching records over one year, one warm sparse run took 8.628 ms; generating
5,842 buckets took 24.062 ms. These establish the query shape and additional
work, not production latency or throughput.

Put `min_doc_count`, `order`, `keyed`, and `format` inside `date_histogram:`;
only per-aggregation `where:` belongs alongside it. Set `min_doc_count: 1` to
avoid generating empty buckets. The default logs a warning for small intervals
over wide date ranges. A custom `format`, such as `"yyyy/MM/dd"` or
`"epoch_millis"`, controls `key_as_string` and keyed bucket names while numeric
`key` remains UTC milliseconds. It uses the same supported patterns as date
ranges, including format alternatives; the first format prints the label.

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
generated only with `min_doc_count: 0`. Strings use the configured `format`,
`time_zone`, and date math. Numeric bounds are integral epoch milliseconds,
regardless of `format` (unlike date-range numeric bounds). Bounds round on the
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
endpoints. Elasticsearch's subsequent
[empty-bucket expansion](https://github.com/elastic/elasticsearch/blob/v8.19.0/server/src/main/java/org/elasticsearch/search/aggregations/bucket/histogram/InternalDateHistogram.java#L396-L465)
does not reapply hard bounds. For example, a one-hour interval with `offset: "+30m"` and both
bounds set to `{min: 0, max: 7_200_000}` can emit an empty bucket at 02:30 UTC,
beyond the hard maximum of 02:00 UTC. Explicit `where:` filters remain available
when the input timestamps themselves must fall within a range.

Advanced formats, nested aggregations, and additional aggregate options remain adapter
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
result. Refined fuzzy searches first run one additional page-token eligibility
query per field, preserving edit-distance, fixed-prefix, and partial-gram rules.
Only eligible tokens are highlighted; broad candidate-only tokens are excluded.
This path warns about extra SQL and long-field/partial-middle costs.
Highlighting does not count matches or alter search ranking. Raw projections fetch
only selected columns plus required highlight inputs; hidden inputs stay out of
the source and raw result attributes. Large pages or long fields increase transfer
and presentation work, so set a suitable page limit.

`:exact`, `:text_start`, `:text_middle`, and `:text_end` also support highlights.
They mark the complete matching field, reflecting Searchkick's whole-field
analysis. A small fragment size does not split that complete match span. Each
SQL field is checked against the same search predicate in a bound page batch,
so a record matching another field does not create a false highlight. Fuzzy
whole-field highlighting retains the matching path's optional dependencies and
cost warnings.

The [captured highlight plans](docs/benchmarks/2026-09-17-highlight-plans.json)
measure 20 supplied texts totaling 8,840 characters on PostgreSQL 18.6 / TIN 1.0.2:

| Page operation | Database execution time |
| --- | --- |
| Two-edit token eligibility | 2.038 ms |
| Native marking of eligible tokens | 2.704 ms |
| Exact `text_middle` field eligibility | 0.273 ms |

The refinement processed 1,360 token occurrences, deduplicated them to 36 terms,
and retained two eligible terms. These helper plans read supplied page text and
`pg_extension`, without scanning model tables. They are single warm executions,
excluding record retrieval, network time, Ruby snippet rendering, and application
latency. Reproduce them with `direnv exec . bundle exec ruby script/explain_highlights.rb`
after preparing the integration test database; larger or less repetitive fields
will have different costs.

Native highlighting preserves document HTML. `encoder: "html"` escapes source
text separately from trusted highlight tags; returned strings are not marked
HTML-safe. Do not mark untrusted native output `html_safe`.

Custom case/accent settings, whitespace tokenization, `max_token_bytes`,
`long_tokens: split/truncate/discard`, and `graphemes: emoji/retain/discard` are
supported for word and partial-word highlights. These are
[TIN index settings](https://planetscale.com/docs/postgres/search/reference/indexes).
Tinkick checks eligible tokens using the field's
actual index analysis, verifies their source spans, and shares the normal tag,
HTML encoding, snippet, and caching behavior. Each field retains its own policy:
a case-preserving name field does not highlight lowercase variants merely because
a case-folding description field matched. Matching stored fragments map to the
original complete graphemes; truncated raw suffixes and discarded words remain
unmarked.

This path logs its extra page-text analysis work; costs grow with the page's text
and eligible tokens. Exact custom highlighting needs only TIN. Fuzzy highlighting
checks its SQL edit-distance helper or extension only when that feature is used;
see [installation](#getting-started). Default-analysis fields keep
the native highlighting path. Explicit native highlighting applies default
analysis even when an index uses different analysis; merely passing the index's
query is insufficient.

Changed token policies and detected long-token splitting use additional native
prefix analysis within matching whitespace runs and log a cost warning. This can
be expensive: the recorded prefix query took 285.655 ms for one synthetic
1,024-character run with a four-byte token limit. See the
[policy-highlight plans](docs/query-plans.md#custom-token-policy-highlighting)
for the complete measurements and reproduction command. Bound page and field
sizes; `fragment_size` limits returned snippets, not the source text analyzed.

Custom phrases reconstruct complete matching spans from cached page text.
Whitespace tokenization supports split, truncate and discard policies, including
preserved or collapsed position gaps. Unicode tokenization supports custom
case/accent, token length, grapheme, and removed-token gap policies. Repeated and overlapping
phrases are merged with word highlights without nested tags. A phrase span includes
source text between its first and last matched token, including discarded internal
context; discarded terms at the query's edges do not extend the highlight.

Phrase reconstruction logs its additional tokenization cost, and complex source
mapping can use the expensive prefix-analysis path described above. Preserved
Unicode gaps require extra queries to map and reanalyze original source slices.
An isolated lexical grapheme whose folded form exceeds TIN's maximum token width
still needs additional boundary reconstruction and currently raises an argument
error; native phrase matching itself is available.

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

Use `sql.active_record` notifications and your Rails logger for timing and query
counts. Searchkick-specific Lograge `searchkick_runtime`, `opaque_id`, and profiling
response hooks are not supplied.

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
identify implemented compatibility paths with known costs. Native fuzzy matching
and adjacent-swap alternatives also add work; uncapped defaults avoid a separate
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
bounded pages, injection-like search text, transpositions, and visibility after
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
The public search accepts `fields`, `where`, `order`, `limit`, `offset`, `page`,
`per_page`, `padding`, `match`, `operator`, `misspellings`, `load`, `total_entries`,
`countless`, `keyset`, `after`, `aggs`, `smart_aggs`, `includes`,
`model_includes`, `scope_results`, `exclude`, `select`, and `highlight`.
Use the detailed sections above for their limits.
Unknown keywords or methods are not compatibility no-ops.
Features proven unsupported by TIN raise `Tinkick::NotImplementedError` with an
explanation naming the backend limitation. Unfinished Tinkick adapters must not
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
| `conversions`, `conversions_v2`, `stem_conversions` | Not implemented; maintain SQL features and an explicit ranking formula. |
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
cover part of Searchkick 6's builder interface; conversion-v2 migration and
Searchkick's own upgrade tasks are not Tinkick procedures. Follow
[CHANGELOG.md](CHANGELOG.md) for Tinkick changes and rerun application search
contracts before upgrading an alpha release.

Thanks to the Searchkick project for the API this gem aims to preserve, and to
the PlanetScale TIN team for the PostgreSQL search engine and reference material.

## License

[MIT](LICENSE.txt), copyright 2026 yknx4.
