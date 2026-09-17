# TIN API research

Reviewed 2026-09-17 UTC against the public PlanetScale documentation, including
the complete Markdown bodies of all eight requested pages (TINQL, scoring,
highlighting, operations, indexes, operator, functions and SQL shapes). These
are documented capabilities, not live test results. Record the actual extension
and PostgreSQL versions when integration testing begins.

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
operators. Phrase syntax has its own escapes. Fuzzy terms must tokenize to one
word and default to a stable prefix of one; `term~P:N` controls that prefix.
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
scoring arguments must be identical across calls on the same relation.
`score` and `full_score` cannot be mixed on one scanned relation. Dead rows can
remain in corpus statistics until maintenance, though matching obeys visibility.
Scores therefore change over time. Guard a zero denominator if normalizing.

Tinkick must test both dense-term settings, add deterministic tie handling,
retain the model primary key for loading, and avoid scoring a plain SQL-only
match-all query. Exact score equivalence to Elasticsearch is not established.

[Recommended SQL shapes](https://planetscale.com/docs/postgres/search/reference/sql-shapes)
favor ranked `ORDER BY ... DESC LIMIT ...` retrieval. SQL filters can cooperate
with ordinary indexes. Scoring both sides of a join requires a matching TIN
predicate on each side. Proposed Tinkick queries must be checked with actual
plans; composability in SQL is not evidence that every shape keeps top-k speed.

## Analysis, highlights and operational constraints

[Overview](https://planetscale.com/docs/postgres/search) explicitly lists no
stemming. This prevents an unconditional promise of Searchkick's default
matching behavior. Unicode case/accent folding and tokenized emoji are useful
primitives, but emoji tokens do not equal emoji-name expansion.

[Highlighting](https://planetscale.com/docs/postgres/search/highlighting) offers
custom tags and automatic or explicit query selection, with overlapping spans
merged. Tinkick still needs fragment sizing, result-key compatibility, and
HTML-safety validation before returning content intended for browser rendering.
The page's BEFORE description and example are not entirely consistent; test
actual span behavior rather than inferring it from that example.

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
These are operational considerations, not missing search features. No cluster
tuning is performed by the gem scaffold.

The linked Settings reference was unavailable during review. Its complete
contents and the deployed extension version remain unverified; no dependency
on undocumented settings is proposed.
