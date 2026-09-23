# Result reference

[Back to the guide](../../README.md)

- [Results and metadata](#results-and-metadata)
- [Highlighting](#highlighting)
- [Pagination and large result sets](#pagination-and-large-result-sets)

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
and fetching the bounded page. It includes query compilation, any tokenization query, and
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
