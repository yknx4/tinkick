# Executed query plans and relevance evidence

Captured on **2026-09-17 at 05:26 UTC** against `tinkick_test`: PostgreSQL 18.6,
TIN 1.0.2, Ruby 4.0.1, Rails 8.1.3.1. The
[complete JSON artifact](benchmarks/2026-09-17-search-plans.json) contains the
actual generated SQL, bind values, returned records, and full
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` output for every case below.

These are small-data execution checks, not a scale benchmark. Each explain ran
once immediately after the normal query, so caches could be warm. Execution
times are PostgreSQL's reported times; they exclude Ruby, connection checkout,
and network time. Other tests used separate fixture tables on the same endpoint.
Do not infer a production latency or throughput guarantee from these numbers.

## Dataset and useful result checks

The [corpus](../test/dummy/test/fixtures/tinkick_test_documents.yml) contains
268 documents: 64 each about fantasy, travel, food, and technical subjects,
plus 12 controlled examples. Background prose incorporates seeded
`Faker::Fantasy::Tolkien` names, places, and poem titles. Document lengths range
from 5 to 286 words. The [relevance tests](../test/relevance_test.rb) assert
matching IDs, excluded documents, ordering relationships, phrases and typo
recovery; they never require a particular numeric score or arbitrary tie order.

For `mithril lantern`, exactly four documents matched and the other 264 were
excluded. The captured results were:

| Document | Words | Why it is useful | Observed score |
| --- | ---: | --- | ---: |
| A miner's lighting handbook | 32 | Repeats both search terms four times | 13.450955 |
| A concise lighting note | 6 | One occurrence of each term, little unrelated text | 12.251762 |
| A miner's equipment handbook | 32 | Same length as the first, one occurrence of each term | 9.417822 |
| An expedition journal with a lighting note | 286 | Same matching sentence as the concise note, followed by unrelated prose | 2.8891592 |

The first two are the expected top-two set. At equal length, higher frequency
beats lower frequency; at equal frequency, the concise text beats the long
document. Both query terms occur in fewer than 10% of this corpus, so the
default dense-term threshold does not erase those ranking signals. TIN retains
index statistics across updates until maintenance, so these score values are
illustrative observations, not stable test constants. See the
[TIN scoring reference](https://planetscale.com/docs/postgres/search/scoring).

The same suite verifies that `Moria Balrog` matches the document containing both
terms in one searched field, excludes a document with the terms split across
fields, and excludes a partial match. Phrase tests distinguish `Gondolin sentries`
from reversed or separated words. `astrolbe` recovers the intended `astrolabe`
document only when misspellings are enabled.

## Measured plans

All lexical examples use `misspellings: false` to isolate pagination and scoring
plan choices. The raw artifact keeps the complete bind values and cursor.

| Case | Plan behavior | DB rows returned | Planning ms | Execution ms | Shared hits / reads |
| --- | --- | ---: | ---: | ---: | ---: |
| Ranked, limit 2 | TIN top-k 2; no sort | 2 | 0.387 | 0.232 | 20 / 0 |
| Countless, limit 2 | TIN top-k 3; no sort | 3 | 0.410 | 0.242 | 20 / 0 |
| Offset 2, limit 2 | Reads/sorts all four matches | 2 | 0.377 | 0.265 | 19 / 0 |
| Lexical keyset after id 1002 | Filters two rows, sorts remaining matches | 2 | 0.458 | 0.256 | 20 / 0 |
| Two fields, `Moria Balrog` | Two TIN scans, disjunction, full-score sort | 1 | 0.761 | 0.299 | 21 / 0 |
| Match-all keyset after id 2 | Primary-key index scan; no sort | 3 | 0.100 | 0.036 | 2 / 0 |

Countless/keyset queries request one extra row to determine whether another
page exists. Only the requested two records are exposed to callers. No count
query is needed for `has_next_page?` or `next_cursor`. Explicit requests for
exact totals still issue SQL counts.

### Ranked and countless searches preserve native top-k

```ruby
SearchDocument.tinkick_search("mithril lantern", misspellings: false, limit: 2)
SearchDocument.tinkick_search("mithril lantern", misspellings: false, limit: 2, countless: true)
```

Selected fields from the captured ranked plan:

```json
{
  "Custom Plan Provider": "Text Search Scan",
  "Index": "index_tinkick_test_documents_on_body",
  "Query": "AND(mithril, lantern)",
  "Scoring": "dense-term elision",
  "Top K": "2",
  "Actual Rows": 2.0,
  "Shared Hit Blocks": 19,
  "Shared Read Blocks": 0
}
```

The countless version has `Top K: "3"` and returns three database rows for the
two-result page. Both use `tin.score`, with no forced primary-key tie sort.

### Offset and keyset have different costs

The offset plan sorts four matching rows before returning the second pair:

```text
Limit: actual rows=2
  Sort: actual rows=4, key=tin.score(ctid) DESC
    Projector: actual rows=4
      Text Search Scan: actual rows=4, no Top K
```

The lexical keyset plan applies `id > 1002`, removes two candidates, and sorts
the remaining two. It has no `OFFSET`, but still performs a TIN scan and sort.
This small query does **not** prove keyset is faster for every lexical search.
Use stable indexed columns for cursor traversal and inspect your real plan.
Relevance ordering remains available through countless pagination; cursors do
not encode changing relevance scores.

For match-all browsing, the captured keyset plan can use the primary-key index
directly:

```json
{
  "Node Type": "Index Scan",
  "Index Name": "tinkick_test_documents_pkey",
  "Index Cond": "(id > '2'::bigint)",
  "Actual Rows": 3.0,
  "Actual Total Time": 0.015
}
```

Countless avoids automatic counts; it does not remove the cost of a requested
offset. Existing page/offset calls keep their behavior and receive actionable
warnings on potentially expensive ranked paths.

### Multiple fields require a documented fallback

The captured two-field query combines a title scan with a body scan and sorts
by `tin.full_score`. The body scan finds the expected one record, and the title
scan finds none. The separate
[multi-field regression record](tin-api.md#multi-field-scoring-regression-and-fallback)
explains why this endpoint requires full scoring to avoid dropping matches.

Full scoring and sorting can cost more on larger corpora. Tinkick warns when
using this path. A combined persisted/generated text column with one TIN index
can preserve single-field top-k when that datasource suits the application.
Combining columns also allows query terms to span the original columns, so it
changes the matching boundary and should be an intentional model design.

## Actual Rails response

The artifact also captures a real Rails request to `/characters.json?q=Hnuleth`.
The response is HTTP 200 and returns the intended Faker character:

```json
{
  "characters": [{
    "id": 1,
    "name": "Hunleth",
    "location": "Kortirion",
    "race": "Huorns",
    "poem": "Where now the horse and the rider?"
  }],
  "has_next_page": false,
  "next_cursor": null,
  "next_page": null
}
```

The [HTTP tests](../test/rails_app_test.rb) also traverse all 64 character
records with cursors, assert that no count/offset SQL is issued for that
traversal, verify poem-only matches, filters, escaping, malformed cursor errors,
and immediate visibility of database writes.

## Partial, exact, and mixed matching

The [match-mode capture](benchmarks/2026-09-17-match-mode-plans.json) records
seven native TIN/SQL query shapes against the same 268-document corpus, refreshed
after the native-backend cleanup. The measurements used Ruby 4.0.1, Rails 8.1.3.1,
PostgreSQL 18.6, and TIN 1.0.2. Each query requested five rows. These are individual
warm-cache observations, not a throughput benchmark or evidence that one strategy
is faster at production size.

| Mode | Rows returned | Execution ms | Observed plan |
| --- | ---: | ---: | --- |
| Token prefix | 4 | 6.024 | TIN Text Search Scan, Top K 5, no Sort |
| Token infix | 4 | 8.177 | TIN Text Search Scan, Top K 5, no Sort |
| Token suffix | 4 | 7.504 | TIN Text Search Scan, Top K 5, no Sort |
| Whole-field prefix | 2 | 2.691 | Sequential scan with normalized SQL predicate |
| Whole-field substring | 4 | 2.761 | Sequential scan with normalized SQL predicate |
| Whole-field exact | 1 | 0.087 | SQL equality; no TIN scoring |
| Mixed whole-field prefix and token search | 4 | 0.944 | TIN/SQL Append, aggregate by ID, join, Sort |

These plans support the warnings in the gem: whole-field normalization scans SQL
rows, and combining SQL matching with native scores groups matching IDs before
sorting. On this small corpus those paths happened to finish faster than the
native wildcard paths; their scaling costs still differ. Exact equality can use
an application B-tree index whose expression and collation match the predicate.
The fixture title column has no such index, so this capture shows a scan.

The native partial paths retain TIN's top-k execution shape. That does not bound
dictionary expansion cost: broader wildcard patterns can still require more work.
These partial modes require `misspellings: false`; fuzzy partial matching raises
`Tinkick::NotImplementedError` instead of generating fuzzy patterns.

Reproduce this capture after loading the normal relevance fixtures:

```sh
direnv exec . bundle exec ruby script/explain_match_modes.rb
```

The [collector](../script/explain_match_modes.rb) checks the database name and
corpus size, captures real bound queries, and performs no writes or migrations.

## Fixed 10,000-document corpus

The [stress capture](benchmarks/2026-09-17-stress-plans.json) uses 9,992 varied
Faker Tolkien documents across four topics and eight ranking/phrase/typo controls,
with seed 314159. Ruby 4.0.1, Rails 8.1.3.1, PostgreSQL 18.6, and TIN 1.0.2
produced these individual observations:

| Query | Visible rows/buckets | Execution ms | Observed plan |
| --- | ---: | ---: | --- |
| Rare two-term relevance, limit 2 | 2 | 0.519 | TIN Text Search Scan, Top K 2; no Sort |
| Relevance countless, limit 20 | 20 | 0.797 | TIN Top K 21; one extra row detects the next page |
| Column keyset, limit 137 | 137 | 0.240 | Primary-key index scan, 138 rows including the probe |
| Category facets over all documents | 5 | 9.254 | Sequential scan of 10,000 rows, SQL grouping/window total and bucket sorting |

Facet cost reflects examining the complete matched set. Neither pagination path
automatically counts that set. The keyset case is match-all with a category filter;
it does not establish the plan for keyset pagination combined with lexical search.
These warm, single-query observations include database execution time, not client
round-trip latency, concurrency, or a production throughput guarantee.

```sh
direnv exec . bundle exec ruby -Itest test/stress_test.rb --fail-fast
direnv exec . bundle exec ruby script/explain_stress.rb
```

The [stress test](../test/stress_test.rb) passed 26 assertions, including result
eligibility, ranking relationships, phrase order, typo recovery, filters, facets,
countless SQL without automatic counts, complete keyset traversal, and immediate
visibility after an update. The collector requires this exact corpus size and
uses a read-only transaction. Run it before another fixture class replaces the
corpus. This is a deterministic regression stress test, not a load generator.

## Native and SQL field weights

The [field-weight capture](benchmarks/2026-09-17-field-weight-plans.json) compares
`body^1` with `body^20000` over the same 268-document relevance corpus. Both
searches returned document IDs 1001 and 1003; countless pagination requested a
third row to detect the next page.

| Field weight | Database execution ms | Observed plan |
| --- | ---: | --- |
| Native `body^1` | 0.421 | TIN Text Search Scan with Top K 3; no Sort |
| SQL `body^20000` | 0.369 | TIN scans four matches, groups scores by primary key, joins records, then sorts and limits |

These single warm executions demonstrate the loss of native top-k for the SQL
weight. Four matching rows are too few to establish relative speed. The warning
concerns growth with the matched set, not a claim that this fixture is slower.
Neither capture includes client latency or a concurrency/load test.

```sh
direnv exec . bundle exec ruby -Itest test/relevance_test.rb --fail-fast
direnv exec . bundle exec ruby script/explain_field_weights.rb
```

The [collector](../script/explain_field_weights.rb) checks `tinkick_test` and the
268-row corpus, captures actual query binds and version metadata, and performs
no writes or migrations. Run it before the stress test replaces the corpus.

## Native highlighting

The [native highlight capture](benchmarks/2026-09-17-highlight-plans.json) uses
20 supplied page fields totaling 8,840 characters on PostgreSQL 18.6 / TIN 1.0.2.
Native fuzzy marking took 0.776 ms; the native SQL substring check used for
whole-field highlighting took 0.279 ms. Both plans return 20 rows from bound page
text and `pg_extension`; they do not scan model tables or reconstruct token
positions. The collector verifies that native fuzzy marking finds both supplied
spellings, `Aragorn` and `Argaorn`, in every field.

These are single warm database executions, excluding query compilation, record
retrieval, network time, and Ruby snippet rendering. They are not application
latency or throughput measurements. Larger pages and fields require fresh
measurement. Reproduce the read-only capture after preparing the test database:

```sh
direnv exec . bundle exec ruby script/explain_highlights.rb
```

## Reproduce

Load the designated test fixtures through their normal tests, then run the
read-only collector:

```sh
direnv exec . bundle exec ruby -Itest -e 'ARGV << "--fail-fast"; %w[test/rails_app_test.rb test/relevance_test.rb].each { |path| require_relative path }'
direnv exec . bundle exec ruby script/explain_search.rb
```

The [collector](../script/explain_search.rb) verifies `tinkick_test` and the
corpus size, captures the actual Active Record SQL/binds, and runs `EXPLAIN
(ANALYZE, BUFFERS, FORMAT JSON)`. It does not migrate or seed data. Re-running it
refreshes the JSON artifact; review the measurements before updating this
document. The fixture corpus establishes correctness and plan shape. Larger
datasets, cold caches, concurrent load, and deployed application latency still
need workload-specific measurement.
