# Searchkick compatibility inventory

## Baseline and status

Reviewed on 2026-09-17 UTC: Searchkick `6.1.2`, source commit
[`93e901a75b11a25101668a616e006b158251b16e`](https://github.com/ankane/searchkick/tree/93e901a75b11a25101668a616e006b158251b16e).
The inventory covers the README and the model, module, relation, query, results,
index, filtering, and Rails integration source. This fixes a reproducible
research baseline; the release compatibility range still needs contract tests.

Implementation is in progress; this inventory describes the complete target,
not a claim that every listed API is available. The literal/phrase compiler
has [live integration coverage](../test/integration/query_text_test.rb).
“Target” means preserve the caller's API. “Unverified” means parity still needs
testing, not that TIN lacks the feature. “Gap” is reserved for an evidenced difference.
“Excluded” follows the model-table datasource decision or the Elasticsearch
low-level exception. TIN similarity is not proof of equivalent behavior.

## Model declaration and datasource

Source: [model.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/model.rb).

| Surface | Tinkick disposition |
| --- | --- |
| `searchkick(**options)`, `search`, `searchkick_search`, `searchkick_options`, `searchkick_klass` | Intentional naming change: use `tinkick`, `tinkick_search`, and Tinkick configuration names. Add `search` only when no method already exists. Both gems must coexist; never alias the Searchkick namespace. |
| `searchable`, `filterable`, `default_fields`, `match`, `word*`, `text*` | Target; validate selected columns and required TIN indexes. Matching modes need separate proofs. |
| `search_data` | Intentional change: validate field names against the model's columns; do not serialize or index returned values. Derived data belongs in stored or generated columns added through Rails migrations. Missing columns must request those migrations. |
| `should_index?`, `search_import`, `unscope`, `inheritance` | No import pipeline. Establish a SQL scope policy; arbitrary Ruby predicates cannot become SQL automatically. |
| `index_name`, `index_prefix`, global suffix | Mapping decision: callers may use these for tenant isolation. Never silently discard them. |
| `language`, `stem*`, synonyms, case/character options, conversions, suggestions | Native analysis controls plus feature-specific translation or verification work; see the evidence table below. |
| `callbacks`, `callback_options`, `batch_size`, `job_options` | Synchronization settings have no datasource role. Decide explicit migration errors versus compatibility no-ops before implementation. |
| `mappings`, `settings`, `merge_mappings`, routing, refresh/window settings | Elasticsearch settings are excluded; migration instructions must identify replacements. |

## Query construction

Sources: [relation.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/relation.rb)
and [query.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb).

| Surface | Tinkick disposition |
| --- | --- |
| Keyword arguments and equivalent fluent calls | Target both forms; validate unknown and unsupported options separately. |
| `fields`, `where`, `where.not`, `order`, `limit`, `offset`, `select` | Target using validated identifiers, bound values, and TINQL generation. |
| `page`, `per_page`, `per`, `padding`, `total_entries` | Target, including defaults and edge behavior. Count in SQL. |
| Keyset / countless pagination | Additive Tinkick extension, opt-in. Stable column cursors for traversal; countless pagination retains relevance ordering. Existing offset/page calls keep their behavior. |
| `rewhere`, `reorder`, `reselect`, `only`, `except` | Preserve replace/merge behavior and cloning. |
| Bang modifiers, `loaded?`, `load`, `first`, `pluck`, Enumerable | Match lazy execution, mutation after loading, and projection semantics. |
| `includes`, `model_includes`, `scope_results` | Load only the selected page; preserve ranking through association loading. |
| `models`, `index_name`, `indices_boost` | Later cross-model/tenant work; do not conflate a SQL table with an Elasticsearch alias. |
| `body`, `body_options`, body-mutating block, `request_params`, `routing`, `scroll`, `type` | Raw backend DSL/transport features excluded or require an explicitly documented replacement. |

Source-level defaults to capture in tests: `search` defaults to `"*"`; terms
become strings; operator is AND; misspellings are enabled; prefix length is zero;
the normal default limit is 10,000. `load` with no argument executes and returns
the relation, whereas `load(false)` configures document-style output. Do not
substitute convenient defaults without recording a compatibility change.

The same pinned [query source](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb)
sets misspellings to distance one (`edit_distance`, with `distance` as an
alias), transpositions enabled, and three maximum expansions by default.
`below` first runs without fuzzy matching and retries only when the successful
response's total count is below the threshold; the retry defaults to twenty
expansions. Per-field misspellings names must belong to the searched fields.
Phrase matching does not add fuzzy branches. Exact-match branches receive
ten times the fuzzy branch's boost, so translating fuzzy eligibility alone
does not reproduce the ranking policy.

## Retrieval features and filters

Source: [query.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb).

| Family | Verified scope and remaining work |
| --- | --- |
| Boolean filters | Equality, negation, arrays/`in`, `all`, ranges, `gt/gte/lt/lte`, `exists`, `_and`, `_or`, `_not`, and legacy `or` have real database coverage, including NULL/missing semantics. Nested JSON correlation and additional scalar types remain adapter work. |
| String filters | `like`, `ilike`, prefix, and native PostgreSQL `~` filters are implemented. `regexp` accepts strings passed unchanged; use PostgreSQL syntax and embedded flags. Ruby Regexp inputs raise `Tinkick::NotImplementedError`; no source/flag adapter is provided. Lucene operators are not emulated: compose `_and`/`_or`/`_not` filters instead. Regex scans warn about cost; matching requires no optional extension. |
| Matching | Whole-word, phrase, exact, word start/middle/end, text start/middle/end, mixed modes, and exclusions are implemented; token boundaries differ from whole-field boundaries. |
| Misspellings | Native TIN Levenshtein distance and stable prefixes, per-field selection, and below-count retry. Native expansion is uncapped. Explicit Elasticsearch caps and `transpositions: true` raise `Tinkick::NotImplementedError` when fuzzy matching is used; phrase and exact modes ignore unused misspelling settings. No custom distance engine is installed. |
| Ranking | Native field boosts and SQL field weights are tested; [captured plans](query-plans.md#native-and-sql-field-weights) show native top-k versus SQL grouping/sorting. Public numeric boosts over table columns, numeric arrays and JSONB numeric paths are tested, including modifiers and missing values. `boost_where`, recency, conversions and model boosts remain adapter work. |
| Aggregations | Terms, numeric/date ranges and histograms, metrics, per-aggregation filters, limits/order, minimum counts, smart facets, and numeric/date bounds are implemented in SQL. Date buckets use native PostgreSQL date_trunc/date_bin and generate_series with fixed offsets or IANA zones. Date math and Java date formats are Elasticsearch-specific and rejected; compute boundaries and labels in the application. Nested shapes remain adapter work. |
| Analysis | `stem: false` uses native matching; requests for stemming or language analyzers raise `Tinkick::NotImplementedError` with migration guidance. Synonyms and emoji-name expansion remain adapter work; native absence does not prove an adapter implementation impossible. |
| Beyond lexical search | Suggestions, similar items, geospatial, KNN, semantic/hybrid search and RRF need separate implementation designs. No absence claim follows from an unimplemented adapter. TIN's overview describes pgvector composition for hybrid retrieval. |

Smart aggregation behavior must follow source/contract tests, not a generic
`GROUP BY` over the final result filter: default handling can remove the facet's
own filter. Scripts and arbitrary Elasticsearch aggregation DSL are excluded.

### Native support versus adapter work

The complete TINQL, scoring, highlighting, operations, indexes, operator,
functions and SQL-shapes pages were read, including their examples and limits.
These classifications supersede a broad “gap” label for the families above.

| Feature | Documented TIN foundation | Classification / remaining work |
| --- | --- | --- |
| Phrases | Adjacency, one-word gaps, position alternatives and tolerance. [Phrases](https://planetscale.com/docs/postgres/search/tinql#phrases) | Native support; translate requests and test analyzer/slop semantics. |
| Fuzzy/prefix/infix/suffix matching | `term~P:N`, `*` and `?`. [TINQL](https://planetscale.com/docs/postgres/search/tinql) | Native whole-token fuzzy matching and nonfuzzy token wildcards are verified on TIN 1.0.2. Combining a wildcard with a fuzzy suffix does not retain wildcard semantics. Fuzzy partials, expansion caps, and single-edit transpositions are not emulated. Nonfuzzy whole-field modes use PostgreSQL `LIKE`. |
| Cross-field relevance | Per-column predicates, combined scores and query boosts. [SQL shapes](https://planetscale.com/docs/postgres/search/reference/sql-shapes) | Native support; one-column indexes do not prevent multi-field search. |
| Numeric/recency/personalized boosts | SQL expressions can accompany ranked TIN queries. [SQL shapes](https://planetscale.com/docs/postgres/search/reference/sql-shapes) | Adapter formulas and performance tests, not a proven missing capability. |
| Full-field highlights/custom tags | `tin.highlight` with explicit tags and optional query. [Highlighting](https://planetscale.com/docs/postgres/search/highlighting) | Default-analysis native highlighting, tags, HTML encoding, page batches, snippets and result helpers are tested. SQL modes verify and mark the complete field. Non-default index tokenization raises `Tinkick::NotImplementedError`: native implicit highlighting rejects it, and explicit highlighting uses default analysis. No token-position reconstruction is performed. Default encoding preserves source HTML; returned strings are not marked HTML-safe. |
| Case/accent controls | Configurable folding, token boundaries, gaps and emoji policy. [Indexes](https://planetscale.com/docs/postgres/search/reference/indexes) | Native support; map options and document migrations. |
| Nested stored JSON text | Text-producing expression indexes. [Indexes](https://planetscale.com/docs/postgres/search/reference/indexes) | Native primitive; field-path validation and nested-object semantics need design. |
| Filters/counts/aggregations | Boolean predicates combine with SQL and counts. [Operator](https://planetscale.com/docs/postgres/search/reference/operator) | Adapter SQL and smart-facet semantics. |
| Token inspection / term quoting | `tin.tokenize`, `tin.maybe_quote`. [Functions](https://planetscale.com/docs/postgres/search/reference/functions) | Helpers verified when selected from `pg_extension`; the current router rejects standalone helper calls. Zero-token input and phrase escaping still need explicit handling. |
| Default stemming | Explicitly absent from TIN's capability table. [Overview](https://planetscale.com/docs/postgres/search) | `stem: false` uses native matching. Requests for stemming or language analyzers raise `Tinkick::NotImplementedError` with migration guidance; no stemming adapter is implemented. |
| Synonyms, suggestions, similar items | Boolean/phrase/term-score primitives offer possible building blocks. | Investigate composition; no blanket impossibility claim. |
| Physical rebuild / replicas | Concurrent index DDL and replica operation. [Indexes](https://planetscale.com/docs/postgres/search/reference/indexes), [Operations](https://planetscale.com/docs/postgres/search/operations) | Operational support; distinct from intentionally removed data import. |

The [scoring reference](https://planetscale.com/docs/postgres/search/scoring)
also documents full scoring, normalization, inspection and term-set overrides.
These are translation tools; they do not prove identical Searchkick ranking.
“Not tested” must remain distinct from “not supported.”

The compiler uses native TIN distance-one misspellings by default, with native
distance/prefix controls. Adjacent swaps consume two Levenshtein edits. Scores
and expansion eligibility remain native: no generated swap alternatives,
Lucene dictionary rewrite, or SQL edit-distance engine is provided. Exact-first
below-threshold retry and per-field fuzzy selection remain available. Explicit
expansion caps and `transpositions: true` raise `Tinkick::NotImplementedError`
when fuzzy matching is used;
`transpositions: false` selects the already-native behavior. Nonfuzzy partial
matching has no Elasticsearch ngram-length ceiling. Literal and native fuzzy
keycap emoji are covered by real TIN tests.

For highlighting, Searchkick passes through the `encoder` option. The
[Elasticsearch encoder contract](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/highlighting-settings)
preserves text by default and escapes source text with `encoder: "html"` while
retaining highlight tags. Tinkick's public `highlight:` keyword and fluent
`.highlight` API cover both modes; a
native highlight function by itself does not implement that optional encoder.

The separate [live evidence record](tin-api.md#live-evidence) identifies the
database/version, actual query shapes, results and documentation discrepancies.
These probes demonstrate usable primitives, not Elasticsearch analyzer,
fuzziness, expansion, ranking or response parity. Operational requirements
(migrations, index maintenance, vacuum and replica retries) must not be labeled
as absent search features.

## Results

Source: [results.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/results.rb).

Preserve the array-like interface (`each`, `any?`, `empty?`, `size`, `length`,
`slice`, `[]`, `to_a`, `to_ary`) and result metadata:

- `total_count` / `total_entries`, `current_page`, `per_page` / `limit_value`,
  `padding`, `total_pages` / `num_pages`, `offset_value` / `offset`,
  `previous_page` / `prev_page`, `next_page`, `first_page?`, `last_page?`,
  `out_of_range?`, `model_name`, `entry_name`.
- `with_hit`, `hits`, `with_score`, `highlights`, `with_highlights`,
  `misspellings?`, `suggestions`, `aggregations`, `aggs`, `took`, `error`,
  `missing_records`, `response`.

`load(false)` projects database values into compatible wrappers. Cached `hits`
expose model primary keys, table identity, native scores, optional source snapshots,
and requested highlights. Cached `response` includes those hits, page timing,
requested aggregations, and ordinary exact totals; countless/keyset responses omit
unknown totals without counting. Public highlight helpers, HTML encoding,
per-field options, and Unicode-safe snippets have integration coverage.
Custom-analysis lexical highlighting raises `Tinkick::NotImplementedError` at the native TIN boundary. Elasticsearch shard/transport
metadata and scroll IDs are excluded. Numeric scores differ across engines.

## Global APIs, lifecycle and integrations

Sources: [searchkick.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick.rb),
[index.rb](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index.rb),
and [README](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/README.md).

- Provide the intended global search and multi-search APIs under `Tinkick`.
  Leave the real `Searchkick` module untouched during side-by-side transitions.
  Multi-search populates existing relations and records individual errors;
  PostgreSQL transaction aborts require deliberate isolation between queries.
- Assess global model options, custom search method name, timeouts, model
  registry, environment/index naming, logging and instrumentation. Do not
  install an Elasticsearch client under `Searchkick.client`.
- No record/model/relation `reindex` implementation, bulk import, queue jobs,
  `reindex_status`, index promotion, or data-copy alias lifecycle. PostgreSQL
  index maintenance is a different operation, managed explicitly.
- Classify `search_index` / `searchkick_index` calls individually: inspection
  (`exists?`, `tokens`, `total_docs`) may have useful SQL equivalents; refresh,
  mappings, settings, store/remove, queue and alias calls must not masquerade
  as supported Elasticsearch operations.
- Error compatibility must include unknown options, invalid query, missing
  schema/index and unsupported-feature reporting. Do not silently weaken a
  filter or fall back to a different search engine.
- Rails/Active Record is the requested integration. Mongoid, Searchjoy,
  pagination libraries and other ecosystem integrations need explicit coverage
  before a wider drop-in claim. No dependency on them is added now.
