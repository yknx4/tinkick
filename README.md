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
model's defaults. Per-field match hashes, boosted names such as `"name^5"`, nested
paths, and wildcard field names are not implemented.

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
column names and `asc`/`desc` directions:

```ruby
Product.search("apple").order(price: :asc, id: :asc)
Product.search("apple").order(:name).reorder(created_at: :desc)
```

`order(_score: :desc)`, arbitrary SQL sort expressions, Elasticsearch missing-value
rules, and nested sorts are not implemented. Leave `order` unset for relevance.
`select`, `reselect`, `only`, `except`, and source-filtering options are not yet
part of the compatible relation API. `map(&:name)` reads the loaded page; it is
not a database projection. For a narrow SQL projection, use an explicitly
constructed ActiveRecord query as shown under [advanced SQL](#advanced-sql-and-debugging).

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

### Metadata still missing

`took`, `response`, `hits`, `with_hit`, `each_with_hit`, `with_details`, `error`,
`missing_records`, `model_name`, `entry_name`, `misspellings?`, suggestions,
aggregation metadata, and public highlight result methods are not implemented.
Do not expect Elasticsearch `_index`, `_shards`, `_source`, scroll IDs, or JSON
response envelopes. Use ActiveRecord instrumentation for timing and explicitly
serialize the visible records for an HTTP response.

## Filtering

Filters use real columns and bound values. These scalar forms are available:

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

JSONB filters accept dotted paths, typed scalar values, scalar arrays, and arrays
of objects:

```ruby
Product.search("*", where: { tags: { all: ["fruit", "fresh"] } })
Product.search("*", where: { "metadata.origin" => "local" })
Product.search("*", where: { "metadata.variants.price" => { gte: 10, lt: 50 } })
```

JSONB equality uses bound JSONPath predicates compatible with GIN. Missing paths,
JSON null, and empty arrays match `nil`/`exists: false`. Range, pattern, and missing
checks log a scan warning; indexed generated columns are often better for frequent
filters. Separate conditions on an object array may match different objects,
following flattened Searchkick object semantics. Arbitrarily nested arrays are
not yet covered. Use JSONB rather than PostgreSQL's `json` type.

Ruby Regexp filters, a `regexp` operator, and geospatial filter hashes remain
implementation work.

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
```

`distance` is an alias for `edit_distance`. Native TIN edits handle insertion,
deletion, and substitution; Tinkick adds exact adjacent swaps for distance one.
The prefix protects the specified number of Unicode codepoints. Options must
use nonnegative integer distances and prefixes.

The default deliberately uses **uncapped native expansion**, rather than
Searchkick's implicit three expansions. It may return additional valid typo
matches. This choice favors TIN performance; numerical scores and tied ordering
are also allowed to differ. Explicit controls must not be silently ignored.

These controls are **not implemented and currently raise**:

- `max_expansions`, including an explicitly requested value of three.
- `below`, which needs an exact-first search and conditional fuzzy retry.
- `fields` inside `misspellings`, which needs per-field fuzzy selection.
- Transpositions with `edit_distance` greater than one. Use
  `transpositions: false` for native larger-distance matching.

Recipe for application-owned `below` behavior, with two queries when needed:

```ruby
results = Product.search(user_text, misspellings: false, limit: 20)
if results.total_count < 5
  results = Product.search(user_text, misspellings: true, limit: 20)
end
```

Keep the same filters and fields on both calls. This recipe is not the missing
fluent `below` option and does not reproduce Searchkick's retry expansion cap.
Per-field typo rules can likewise use separately compiled native SQL predicates.
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
| `:word_start`, `:word_middle`, `:word_end` | Available | Native token wildcards; escaped dictionary patterns for distance-one typos. |
| `:text_start`, `:text_middle`, `:text_end` | Available | Whole-field SQL matching with optional `unaccent`; distance-zero/one matching. |
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

### Case, accents, whitespace, and emoji

The current compiler uses TIN's default Unicode analysis. Case and accents fold,
so `JALAPEÑO` can match `jalapeno`; hyphens can split words, while underscores and
apostrophes can remain within tokens. Emoji can be indexed as tokens. This does
not provide Searchkick's emoji-to-name expansion: `🍰` is not automatically
translated to `cake`. The `emoji` option is not implemented; an application can
normalize both stored search text and query text with a chosen emoji dictionary.

Searchkick's extra-whitespace/word-joining analyzers are not reproduced:
`dishwasher` and `dish washer` need not have the same matches. Persist an
application-normalized search column if that behavior is required.

TIN provides case/accent preservation and tokenizer options, but Tinkick's
`case_sensitive`, `special_characters`, and custom analyzer mappings are not yet
implemented. Do not change index analysis independently and assume the compiler
will follow it. Index/query analysis must agree; changed index tokenization
requires rebuilding stored index entries through explicit operations.
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

`exclude` and demotion through `boost_where` are also not implemented. A direct
TINQL recipe can express an exclusion:

```ruby
Product.where("name ==> ?", 'butter AND NOT "peanut butter"')
```

This fixed TINQL example is an ActiveRecord query. For user-entered values, build
and escape a query deliberately; SQL parameter binding does not make arbitrary
text literal within the TINQL language.

## Boosting, conversions, and personalization

`fields("title^10")`, `boost_by`, `boost_where`, `boost_by_recency`,
`boost_by_distance`, `indices_boost`, and `conversions`/`conversions_v2` are not
implemented. Default scores come from TIN, without synthetic exact-versus-fuzzy
boosts or a forced primary-key tie order.

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

`aggs`, `aggregations`, `smart_aggs`, per-aggregation options, and the aggregation
response envelope are not implemented. PostgreSQL can perform aggregates directly.
Recipe, returning a Ruby hash rather than Searchkick buckets:

```ruby
matches = Product.where("name ==> ?", "apple").where(in_stock: true)
counts = matches.group(:category).count
average_price = matches.average(:price)
```

Use the complete filtered SQL scope, not `Product.search(...).to_a`, for totals.
These other upstream features need explicit SQL equivalents and result mapping:

| Feature | Application SQL direction |
| --- | --- |
| Terms, limit, ordering, minimum count | `GROUP BY`, aggregate ordering, `LIMIT`, `HAVING count(*) >= ...` |
| Range and date-range buckets | `CASE` or filtered aggregates with explicit interval boundaries |
| Numeric histogram | A chosen bucket-width expression |
| Date histogram | `date_trunc` with explicit timezone and interval semantics |
| Average, min, max, sum | SQL aggregate functions |
| Cardinality | `count(DISTINCT column)` with defined NULL behavior |
| Nested aggregations | Multiple grouping levels or separate bounded queries |
| Per-facet filters / smart facets | Separate scopes that intentionally retain or remove each facet's own filter |
| Scripted aggregations | Reviewed SQL expressions; Elasticsearch/Painless scripts are excluded |

Do not describe `smart_aggs` as simply grouping the final result page or applying
all final filters unchanged. Its self-filter behavior needs a compatibility
adapter. TIN documents restrictions for some aggregate/window query shapes;
materialized CTEs can be required. Check the real plan and
[SQL shape guidance](https://planetscale.com/docs/postgres/search/reference/sql-shapes).

## Highlighting

TIN supports matched spans and custom tags. Tinkick has a tested **internal**
full-field `Tinkick::Highlighter` helper, but `highlight`, `highlights`,
`with_highlights`, per-field options, multiple snippets, and `fragment_size` are
not integrated into public search results yet. A model `highlight:` declaration
is not accepted.

Recipe using SQL for fixed TINQL, returning model rows with an extra attribute:

```ruby
Product.where("name ==> ?", "apple")
  .select("products.*, tin.highlight(name, '<em>', '</em>') AS highlighted_name")
  .limit(20)
```

Native highlighting preserves document HTML. The internal helper supports
`encoder: "html"` to escape source text separately from trusted highlight tags;
its returned string is not marked HTML-safe. Do not mark untrusted native output
`html_safe`. Snippet boundaries, overlapping spans, and source markup need their
own presentation rules. See [TIN highlighting](https://planetscale.com/docs/postgres/search/highlighting).

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
`includes`, `model_includes`, and `scope_results` are not implemented on Tinkick
relations. For eager loading, construct a bounded ActiveRecord search scope and
use its normal association loading; do not preload every matching row merely to
paginate it.

### Multiple models and multi-search

Global `Tinkick.search`, `models`, `indices_boost`, and `Tinkick.multi_search` are
not implemented. Query each model explicitly, or design a SQL `UNION ALL` over
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
[filtering](#filtering). Text search through a JSONB expression index is still
implementation work. A generated text column can already expose a same-row JSON
property. Flattened array-of-object filters do not preserve same-object correlation;
use explicit `EXISTS`/joins or JSON predicates when that distinction matters.

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

Searchkick's `debug`, `explain`, `search_index.tokens`, and raw `response` methods
are not implemented. Recipe queries can inspect the native engine:

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
writes, plus countless navigation and cursor traversal. Local verification on
Ruby 4.0.1 passed **195 tests and 1,081 assertions** on both Rails 8.0.5.1
(JSON 2.21.2) and Rails 8.1.3.1 (JSON 3.0.2), with no failures or skips.
This includes 11 HTTP tests and seven relevance-corpus tests. These are local
results; remote CI has not been run. See the tests and
[development guide](docs/development.md) for verification details. A fixture
corpus is not evidence of complete Searchkick parity or a production-scale benchmark.

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

The current model declaration accepts `searchable`, `default_fields`, `match`, and `stem: false`.
The public search accepts `fields`, `where`, `order`, `limit`, `offset`, `page`,
`per_page`, `padding`, `match`, `operator`, `misspellings`, `load`, `total_entries`,
`countless`, `keyset`, and `after`. Use the detailed sections above for their limits.
Unknown keywords or methods are not compatibility no-ops.
Features proven unsupported by TIN raise `Tinkick::NotImplementedError` with an
explanation naming the backend limitation. Unfinished Tinkick adapters must not
be mislabeled as TIN limitations; invalid inputs remain validation errors.

The following reference maps less common upstream options to their current status:

| Searchkick API or configuration | Status / replacement |
| --- | --- |
| `searchable`, `default_fields`, `match` | Available within the supported modes/types. |
| `filterable` | Not accepted. Filter real scalar columns and add ordinary PostgreSQL indexes as needed. |
| `unscope`, `inheritance`, query `type` | Not implemented as Searchkick options; define explicit model scopes and test the intended STI/tenant behavior. |
| Global `model_options` | Not implemented; declare each model explicitly. |
| `search_method_name` | Not implemented; `tinkick_search` is the explicit backend entry point. |
| `index_name`, dynamic names, prefix/suffix | Excluded index identity API; use explicit database/schema/table tenancy. |
| Custom `search_document_id` | Excluded document identity API; results use the model's single primary key. |
| `mappings`, `merge_mappings`, `settings` | Excluded server configuration DSL; use migrations and native index options. |
| `case_sensitive`, `special_characters`, language/stem options | Adapter mapping missing; see analysis limitations above. |
| `search_synonyms`, synonym file/reload | Not implemented; application synonym storage/expansion is a recipe. |
| `conversions`, `conversions_v2`, `stem_conversions` | Not implemented; maintain SQL features and an explicit ranking formula. |
| `suggest`, `similar`, `emoji`, `exclude` | Not implemented; see the corresponding recipes. |
| `locations`, `geo_shape`, `knn` | Not implemented; design explicit PostGIS/pgvector integration where available. |
| `callbacks`, queues, job priorities/parent jobs | Excluded synchronization configuration. |
| Import batch size, resume, partial/bulk reindex | Excluded document import API; update real data with application jobs/migrations. |
| Routing, request parameters, opaque IDs | Excluded transport API; use SQL filters, database routing, and Rails instrumentation. |
| `timeout`, `search_timeout`, `client_options` | Not implemented; configure database timeouts/pooling. |
| `includes`, `model_includes`, `scope_results` | Compatible result-loading adapters not implemented. |
| `select`, source filtering, `reselect`, `only`, `except` | Not implemented; use an explicit SQL projection recipe. |
| `body`, `body_options`, query-mutating blocks | Excluded Elasticsearch DSL; use reviewed native SQL. |
| `search_index`/`searchkick_index` inspection | Not implemented; use PostgreSQL catalogs and TIN helpers. |
| Index refresh, clean/promote/store/remove, queue inspection | Excluded external-index lifecycle. |
| `multi_search`, global search, `models`, model boosts | Not implemented; separate queries or explicit SQL combination. |
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
