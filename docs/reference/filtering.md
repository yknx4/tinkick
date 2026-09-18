# Filter reference

[Back to the guide](../../README.md)

- [Filtering](#filtering)

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
See the [recursive JSONB plans](../../docs/recursive-json-plans.md) for measured
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

