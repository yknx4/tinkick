# Custom search with Active Record

Start with an authorized model scope. Use `block:` or a Ruby block to change the
scored relation before pagination; return a relation for the same model:

```ruby
CatalogEntry.where(collection_id: allowed_ids).tinkick_search(
  query, fields: [:search_text], misspellings: false, countless: true, limit: 20,
  block: ->(relation) { relation.where(has_extended_metadata: true) }
)
```

`.merge(scope)` adds SQL/Active Record/Arel conditions to a Tinkick search.
`.to_relation` exposes ordinary Active Record, including joins and CTEs. Keep
`id` and `_tinkick_score` when changing projections. Hooks may run again for
counts, typo thresholds or aggregations: keep them free of side effects.
Tinkick applies page limits afterward; keyset pagination also reapplies its
configured column order. See the [hook contract](reference/querying.md#active-record-sql-and-arel).

## Tested building blocks

The [catalog tests](../test/catalog_search_test.rb) use 136 synthetic entries,
including Faker Tolkien creators, unrelated topics and curated matching controls.
They run in the Rails test app against real PostgreSQL/TIN.

| Need | Supported approach |
| --- | --- |
| Title, creator or combined search | Select `fields:`; index each text field. A generated `search_text` lets terms match across title and creator. |
| Partial matches and typos | `match: :word_middle, misspellings: false`; optionally retry with native `:word` misspellings below a small result threshold. No fuzzy-substring emulation. |
| Safety, age, images, extended metadata | Boolean/range `where:` filters over stored columns. |
| One/many collections, statuses and levels | Scalar/list/enum filters; array membership and `exists: true` (excludes empty arrays). Keep collection authorization in the starting scope. |
| Ordinary ranking | Native relevance, field weights, `boost_where` and `boost_by`. Exact score parity with another engine is not promised. |
| Custom ranking | SQL `CASE`, multiplication, logarithms, a capped sum, and an exact-title bonus; [tested recipes](../test/support/catalog_sql.rb). |
| Group editions; prefer extended metadata | Window functions choose one edition and preserve the group's best score before pagination; [tests](../test/catalog_collapse_test.rb). |
| Pages, countless results, preloads, raw hashes | `page`/`per_page`, `countless`, `includes`, `load: false`. Prefer stable-column keyset pagination for deep browsing. |
| HTTP and SQL composition | [Rails request tests](../test/catalog_application_test.rb) and [SQL/Arel/CTE tests](../test/integration/active_record_composition_test.rb). |
| Time limits | Execute the lazy search inside a transaction with `SET LOCAL statement_timeout`; rescue `ActiveRecord::QueryCanceled` outside it. Use a top-level transaction: our TIN router intermittently rejected savepoint rollback after cancellation. Cancellation raises rather than returning partial results. |
| Response caching | Rails cache with a separate Tinkick namespace, query/filter/order/page/scoring identity and response version. Explicit invalidation or expiry remains application-owned. |

The SQL helpers are executable application recipes, **not new gem APIs**. For
example, adapt their model/table names and call the recipe from a hook:

```ruby
block: ->(relation) { CatalogSql.collapse(CatalogSql.rank(relation)) }
```

The grouping recipe counts **groups**, while an ungrouped search counts rows.
It partitions by collection and group key; extended metadata wins edition
selection, but the highest group score determines ordering. Filters apply
before grouping. Custom SQL must preserve that authorization boundary.

## Schema and application responsibilities

Add Rails migrations for searchable `text` columns and TIN indexes. Existing
`varchar` fields need conversion or stored/generated text search columns.
Generated columns can combine same-row fields. Values derived from associations,
external metadata or application classifiers need stored columns plus application
updates/backfills. Keep normalization identical for stored exact titles and input.
`search_data` does not persist any of these values; use `tinkick_search_data` for
schema checks alongside Searchkick.

Keep input decoding/normalization, invalid-filter/no-collection guards, feature
flags, typo-suppression policy, background work and metrics in the application.
Background decisions can use the returned page size; no search engine schedules
those jobs. Drop Elasticsearch escaping, shard routing and request-body mutation:
use literal search terms, collection filters and the relation hook. Do not reuse
cached Elasticsearch response objects. No extra PostgreSQL extension is needed
for these recipes.

## Cost and reproduction

Ranking/grouping SQL can process and sort all matches. The recipes emit warnings;
`Tinkick.warnings = false` disables them. The [captured plans](benchmarks/2026-09-17-catalog-plans.json)
show native top-k reading two results, custom ranking sorting five local matches,
and grouping reducing those five to four groups. Warm execution times were
0.190 / 0.304 / 0.467 ms respectively on this tiny fixture corpus—not production
latency estimates. Recheck selective and broad terms on representative data.

```sh
direnv exec . bundle exec ruby -Itest -e 'Dir["test/catalog*_test.rb"].sort.each { |f| require_relative f }'
direnv exec . bundle exec ruby script/explain_catalog.rb
```

The plan script is read-only and expects the test fixtures already loaded.
Lead verifies behavior where supported; its confirmed limitations remain in the
separate [Lead CI exclusions](lead-ci.md).
