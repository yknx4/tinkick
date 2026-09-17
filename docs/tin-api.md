# TIN API research

Reviewed 2026-09-17 UTC against the public PlanetScale documentation, including
the complete bodies of all eight requested pages (TINQL, scoring, highlighting,
operations, indexes, operator, functions and SQL shapes). The sections below
describe documented capabilities. The separate [live evidence](#live-evidence)
section records observations from PostgreSQL 18.6 with TIN 1.0.2; neither kind
of evidence establishes complete Searchkick compatibility.

## Index and operator contract

[Indexes](https://planetscale.com/docs/postgres/search/reference/indexes):
TIN indexes one `text`/`citext` source or text-producing expression. Each field
needs its own index; expression queries must match the indexed expression.
Partial indexes require an implied predicate. Concurrent creation/rebuild is
documented. Index tokenization changes require rebuilding existing entries.

[Operator](https://planetscale.com/docs/postgres/search/reference/operator):
`column ==> $1` returns a boolean and accepts prepared parameters. Combine it
with ordinary SQL filters or other indexed fields. `==> ANY (...)` is available.
Zero-token input matches nothing; explicitly empty phrase syntax errors.

For Tinkick, schema migrations own extension/index creation. There is no DDL
on gem load, model declaration, or an ordinary search request.

## SQL functions

[Function reference](https://planetscale.com/docs/postgres/search/reference/functions):

| Function | Role |
| --- | --- |
| `tin.score(ctid, ...)` | BM25 with optional dense-term and scoring controls. |
| `tin.full_score(ctid, ...)` | Scoring without dense-term elision. |
| `tin.max_score(ctid)` | Highest visible match score, used for normalization. |
| `tin.score_inspect(index, query, ...)` | Inspect scored terms and weights. |
| `tin.highlight(text, begin_tag, end_tag, query)` | Mark matched spans. |
| `tin.highlight_ansi(text, wrap_to, query)` | Terminal highlighting. |
| `tin.tokenize(text, ...)` | Inspect tokenization with the index's options. |
| `tin.maybe_quote(text)` | Quote TINQL terms needing special handling. |
| `tin.fsck(index, heapcheck)` | Read-only consistency inspection requiring index ownership. |

## Query language

[TINQL](https://planetscale.com/docs/postgres/search/tinql) supports terms,
phrases, wildcard/regex/fuzzy matching, term ranges, boosts, boolean alternatives,
minimum-match groups, proximity, span relations and positional filters.
Keywords are uppercase; juxtaposition means AND. NOT is only used in compound
operators. Phrase syntax has its own escapes, including literal underscores
and brackets. The documentation requires fuzzy terms to tokenize to one word
and defaults to a stable prefix of one; `term~P:N` controls that prefix.
Phrases support adjacency, explicit gaps, position alternatives and tolerance.
Boost factors are bounded.

Compiler requirements inferred for Tinkick: escape literal user text before
adding operators; bind the complete TINQL value separately from SQL. SQL binding
alone does not prevent a user term from becoming a TINQL operator. Test reserved
words, quotes, backslashes, punctuation, Unicode, hyphens, empty input and `*`.
Do not equate word wildcards with whole-field substring semantics.

## Ranking and loading

[Scoring](https://planetscale.com/docs/postgres/search/scoring): scoring requires
a TIN scan in the same query. `ctid` identifies the scanned tuple, not a durable
record ID. Multiple fields contribute to the score. Default dense-term elision
can make every score zero on tiny fixtures. Full scoring costs more. Some
scoring arguments (`dense_ratio`, `term_add`, `term_replace`) must be written
identically across calls on the same relation; `k1` and `b` may differ.
`score` and `full_score` cannot be mixed on one scanned relation. Dead rows can
remain in corpus statistics until maintenance, though matching obeys visibility.
Scores therefore change over time. Guard a zero denominator if normalizing.
An explicit boost, including `^1.0`, pins a term against dense-term elision;
field-boost translation therefore also affects which terms contribute.

Tinkick retains the model primary key, avoids scoring plain SQL-only match-all
queries, and leaves default relevance ties to TIN. Callers can request explicit
column ordering when deterministic ties matter, with its potential sorting cost.
Exact score equivalence to Elasticsearch is not established.

[Recommended SQL shapes](https://planetscale.com/docs/postgres/search/reference/sql-shapes)
favor ranked `ORDER BY ... DESC LIMIT ...` retrieval. SQL filters can cooperate
with ordinary indexes. Scoring both sides of a join requires a matching TIN
predicate on each side. Proposed Tinkick queries must be checked with actual
plans; composability in SQL is not evidence that every shape keeps top-k speed.
The reference also documents `LATERAL` searches whose query comes from an outer
row, allowing per-row top-k retrieval. One such shape succeeded through the
current PlanetScale router; the bounded probe is recorded below.

## Analysis, highlights and operational constraints

[Overview](https://planetscale.com/docs/postgres/search) explicitly lists no
stemming. This prevents an unconditional promise of Searchkick's default
matching behavior. Unicode case/accent folding and tokenized emoji are useful
primitives, but emoji tokens do not equal emoji-name expansion.

[Highlighting](https://planetscale.com/docs/postgres/search/highlighting) offers
custom tags and automatic or explicit query selection, with overlapping spans
merged. `$QUERY_PART` escapes the query description placed in a tag; this does
not promise escaping of document content. Tinkick still needs fragment sizing,
result-key compatibility, and HTML-safety handling. The page's BEFORE prose
and example differ; the live result below agrees with the example.

[Limitations](https://planetscale.com/docs/postgres/search/reference/limitations):
partitioned parents require usable TIN indexes on planned leaves; relevance
statistics are per partition. Some aggregate/window shapes need materialized
CTEs. Index storage retains its high-water size until rebuild. Replica queries
can encounter SQLSTATE `40001`.

[Operations](https://planetscale.com/docs/postgres/search/operations): replica
search needs `hot_standby_feedback`; vacuum affects count performance and dead
entries. Exact counts apply to the visible snapshot, not freshness relative to
the writer. Build memory constrains worker count and fragmentation; serving
parallelism depends on segments and worker limits. Storage/cache behavior,
readahead, work memory, planner costs and WAL settings affect performance.
These are operational considerations, not missing search features. The gem
does not tune cluster settings.

[Settings](https://planetscale.com/docs/postgres/search/reference/settings)
was subsequently available and read in full. It documents custom scans,
maintenance modes, build I/O and worker controls, page-reuse statistics, and
debug settings that force alternative query plans. These provide possible
diagnostic tools; their availability through the current router has not been
tested, and the gem does not change them.

## Live evidence

Read-only probes on 2026-09-17 UTC first checked `current_database()` was
`tinkick_test` and enabled `default_transaction_read_only`. PostgreSQL reported
`18.6 (Debian 18.6-1.pgdg13+2)` and `pg_extension` reported TIN `1.0.2`.
The indexed probes used the Rails-migrated `tinkick_test_products` table and
its `name`/`description` TIN indexes. SQL values were bound parameters.
These observations describe that endpoint and version, not every TIN release.

### Router and helper execution

The router rejected standalone `SELECT tin.maybe_quote($1)` and
`SELECT tin.highlight(...)` with SQLSTATE `NK013` (unimplemented function
opcode). `SELECT * FROM tin.tokenize($1)` also raised `NK013`; an
`ARRAY(SELECT ...)` tokenization expression was rejected as an unsupported
array subquery. These are execution-shape restrictions, not missing TIN helpers.

Selecting the helpers from the extension catalog succeeded:

```sql
SELECT tin.tokenize($1) FROM pg_extension WHERE extname = 'tin';
SELECT tin.maybe_quote($1) FROM pg_extension WHERE extname = 'tin';
SELECT tin.highlight($1, $2, $3, $4) FROM pg_extension WHERE extname = 'tin';
```

Default tokens included `Jalapeño` → `jalapeno`, `wi-fi` → `wi`, `fi`,
`foo_bar` → `foo_bar`, and emoji retained as tokens. The explicit whitespace
tokenizer with case/accent preservation returned `Jalapeño`, `AND`, `wi-fi`
unchanged. Helpers must use the same analysis options as their target index.
`tin.maybe_quote('AND')` returned `"AND"`; quoting an empty string returned
`""`, so quoting alone does not make zero-token input a valid query.

### Literal, phrase and fuzzy matching

| Probe | Observed result |
| --- | --- |
| Indexed `apple OR pear` | Matched both Red Apple and Green Pear. |
| Indexed `"apple OR pear"` | Matched neither; the operator became literal phrase content. |
| Empty input or `!!!` | Matched no rows. |
| Explicit `""` | Raised SQLSTATE `XX000` with an empty-phrase parse error. |
| `*` / `"*"` | Matched every fixture / no fixtures. |
| Document `foo_bar`, query `"foo_bar"` / `"foo\_bar"` | False / true. Phrase underscores must be escaped. |
| Document `fuji crisp apple`, query `"fuji apple"` / `"fuji apple"~1` | False / true; phrase tolerance allows the extra word. |
| Indexed `app*` / `*pple` | Both matched Red Apple; this proves token wildcards, not whole-field matching. |
| Document `maple`, query `apple~0:2` / `apple~1:2` | True / false; the stable-prefix parameter changes matching. |
| Indexed `appl~0:1` / `aplpe~0:1` | Matched Red Apple / no rows. Adjacent transposition was not one native edit. |
| Indexed `red-apple~0:1` / `ryd-appl~0:1` | Exact spelling matched / inexact spelling did not. The documented multi-token error did not occur on 1.0.2. |
| Indexed `ryd~0:1 AND appl~0:1` | Matched Red Apple. Apply fuzzy modifiers to individual analyzed tokens. |
| Indexed `"apple"~0:1` | Raised a parse error; a quoted phrase cannot take this fuzzy-prefix suffix. |

The literal, phrase, keycap and explicit native fuzzy compiler now have automated
coverage in `test/integration/query_text_test.rb`. The earlier probes above
remain a separate evidence record; neither proves a complete misspellings adapter.

### Highlighting and scoring

Both automatic and explicit indexed highlighting returned
`Red <em>Apple</em>`. Explicit `a BEFORE b` over `b a b` returned
`b <b>a</b> <b>b</b>`, marking both witnessing spans. Input document HTML
remained unchanged apart from added tags: an existing `<script>` element was
not escaped. Empty or invalid explicit highlight queries sometimes returned
unmodified text instead of the parse error raised by `==>`; highlighting must
not serve as a query validator.

A later isolated test on TIN 1.0.2 used a whitespace index with case and accent
preservation. Implicit highlighting raised SQLSTATE `XX000`: nondefault index
tokenization requires an explicit query. Explicit indexed-column highlighting
still used default analysis: `MATCHES FooBar` did not mark the preserved matching
token, while `MATCHES jalapeno` also marked accented/case variants. Supplying an
explicit query therefore does not establish analyzer-equivalent highlighting.
Tinkick raises `Tinkick::NotImplementedError` for lexical highlighting with
non-default index tokenization. It does not reconstruct source positions or use
a different analyzer silently; ordinary matching remains available.

Default scoring, full scoring, and disabled dense-term elision each returned
`0.9517491` for the two visible apple/pear matches during the probe. That is
not a stable expected value: previous writes affect retained corpus statistics.
Boosting apple by two returned `1.9034982` for that match, while pear remained
`0.9517491`. Mixing `score` and `full_score` on one relation failed as
documented; calls without a TIN scan also failed. Multi-field retrieval now has
automated coverage. Boosted ranking and normalized-score behavior still need
representative automated coverage and query-plan inspection.

The executable Query integration tests also check the actual ranked SQL with
`EXPLAIN (FORMAT JSON)`. Single-field native `tin.score`, a score-only descending
order and `LIMIT` retain TIN's top-k path. On this endpoint, adding even `OFFSET 0`
caused an extra sort and removed top-k. The adapter omits a zero offset and warns on
nonzero offset pagination. No forced primary-key tie sort or synthetic fuzzy
boost is added to the normal relevance query. Stable column cursor pagination
is an explicit alternative ordering, not a claim that arbitrary column sorts
have the same TIN top-k plan.

### Parameterized LATERAL probe

A read-only probe on the same TIN 1.0.2 endpoint inspected dictionary candidates
in a materialized CTE, aggregated them into query text, and passed that text to
a `CROSS JOIN LATERAL` search of the existing character table. It returned the
expected `Hunleth` record. `EXPLAIN` showed a `Text Search Scan` with query
`$exec1`, dense-term elision, and `Top K: "10"` for the inner search. Candidate
selection had its own sort. A scalar-subquery variant also returned the record,
but added a result sort and lost top-k.

This ad hoc probe establishes those SQL shapes through the router; it is not an
implemented expansion-cap API, an automated compatibility test, or part of the
separate [captured query-plan artifact](query-plans.md).

### Multi-field scoring regression and fallback

On the same TIN 1.0.2 endpoint, a fresh connection reproduced a discrepancy for
`name ==> 'apple OR ripe' OR description ==> 'apple OR ripe'`: `COUNT(*)` and a
projection without scoring returned two matches, while selecting `tin.score(ctid)`
returned no rows, with or without an explicit order. Selecting
`tin.full_score(ctid)` returned both rows. The plan used a TIN multi-index scan
with the `Stripe Solve` strategy. This is an observed regression in this query
shape and endpoint state, not evidence that TIN lacks multi-field search.

Tinkick therefore uses full scoring for multi-field lexical searches and warns
about full-scoring and sorting costs. Single-field queries keep native
`tin.score`; default relevance ordering without an offset preserves the tested
top-k path. A stored/generated combined column with one TIN
index is the recommended option when its matching semantics fit the application.
The varied-corpus tests exercise a positive multi-field query and exclude terms
split between fields; they do not weaken matching assertions to accommodate this
endpoint behavior.
