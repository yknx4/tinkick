# Native JSONB conversion scoring plans

The [recorded plans](benchmarks/2026-09-17-conversion-plans.json) exercise public
searches with legacy `conversions`, `conversions_v2`, and a v2 factor. PostgreSQL
JSONB iteration, `lower`, numeric casts, and arithmetic provide the conversion
contribution. The collector uses the existing `metadata` and `conversion_counts`
JSONB columns.

```sh
direnv exec . bundle exec ruby script/explain_conversions.rb
```

The collector checks `current_database() = 'tinkick_test'` and the TIN extension,
then inserts 72 deterministic Faker Tolkien records in a transaction. The
corpus has 48 lexical matches and 24 unrelated records with much larger
conversion counts. Unique negative IDs, a description marker, and a lexical
marker isolate the owned rows. The transaction rolls back and the artifact
verifies zero remaining IDs and marker rows. It changes no schema, statistics,
or planner settings.

Each case checks the same complete set of 48 matching IDs, the total count, the
expected winner, and every returned score against the unboosted baseline.
Conversion counts never add the unrelated high-count records to the result set.
The native winner is Holdwine's repeated-term forge record. Legacy counts move
Berylla Boffin's record first; v2 counts move Hyarmendacil's record first.

The model declares both legacy and v2 columns. Searches use the whole conversion
term `Mithril.Lantern`, independently of the lexical query. The dot remains part
of the key. The legacy fixture includes two case variants with counts of one;
PostgreSQL case-insensitive matching sums them to two. Large counts under the
different key `mithril` do not contribute. Other fixtures include SQL-null
columns and JSON-null counts.

Captured with Ruby 4.0.1, ActiveRecord 8.1.3.1, PostgreSQL 18.6 on Neki, and
TIN 1.0.2. Each page contains five results:

| Case | First result | Observed plan | Search execution time |
| --- | --- | --- | ---: |
| Both conversion versions disabled | Holdwine | TIN Top K 5 | 0.621 ms |
| Legacy default | Berylla Boffin | TIN scan and top-N sort | 1.000 ms |
| V2 only, default factor | Hyarmendacil | TIN scan and top-N sort | 1.012 ms |
| V2 only, factor `0.25` | Hyarmendacil | TIN scan and top-N sort | 1.047 ms |
| Legacy plus v2 factor `0.25` | Hyarmendacil | TIN scan and top-N sort | 1.376 ms |

Hyarmendacil's native score is approximately 2.824677. Its legacy count is 2
and v2 count is 800. The captured v2 scores are approximately 802.824677 at
factor one and 202.824677 at factor `0.25`. Enabling legacy as well produces
204.824677. The factor scales the conversion contribution, preserving the native
score as an additive term.

The disabled control's TIN scan returns five rows. Each conversion plan scores
all 48 matching rows before sorting. Case-insensitive legacy and v2 lookup each
execute a `jsonb_each` function scan 48 times; the combined case has two such
subplans, each with 48 loops. These plans demonstrate the per-row JSONB work and
loss of native top-k execution for this query shape. The feature logs a cost
warning. See [PostgreSQL JSONB functions](https://www.postgresql.org/docs/current/functions-json.html)
and [TIN scoring](https://planetscale.com/docs/postgres/search/scoring).

The artifact retains complete SQL, bind values, options, matching IDs, fixture
counts, returned scores, and `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` plans.
Measurements exclude application/network work and can benefit from warm caches.
Existing statistics, mutable index entries, the synthetic marker, and the small
corpus affect planner choices. These observations establish execution behavior;
they are not production latency or throughput benchmarks.
