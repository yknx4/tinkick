# Matching reference

[Back to the guide](../../README.md)

- [Matching and analysis](#matching-and-analysis)
- [Autocomplete and suggestions](#autocomplete-and-suggestions)

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
[compiler integration tests](../../test/integration/query_text_test.rb).

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
