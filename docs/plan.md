# Implementation plan

## Confirmed design

- Ruby 4.x+ and Rails/Active Record 8.x+; retain Searchkick caller-facing names
  wherever the TIN backend can honor their behavior.
- Query the model's own PostgreSQL table. No document table, copied JSON
  datasource, importer, synchronization callbacks/jobs, or data reindexing.
- Use `search_data` as a schema sanity check. Every declared field must exist
  in the model table; otherwise fail with the missing names and migration
  guidance. Do not use the returned Ruby values as the search datasource.
- Computed search fields belong in application-owned persisted columns or
  PostgreSQL generated columns. Schema/index changes happen in migrations.
  Supply Rails migrations that consuming applications can import.
- Preserve the existing `.envrc` and `dev.ejson` development/test setup.

## Milestones and exit evidence

### 0. Scaffold — completed

Package a prerelease gem with explicit runtime requirements, Minitest Rails
boot checks, Shopify RuboCop, RBS validation/formatting, strict Steep, and CI.
Produce a built gem with an explicit file allowlist. Include no functioning
search facade or stub that suggests query support exists.

Exit evidence: library loads with and without Rails already initialized,
without connecting to a database; required checks pass; built contents include
the library/signatures/docs and exclude local secrets.

### 1. Model registration and field validation

Add the Active Record integration and `searchkick` declaration using failing
Minitest coverage first. Validate field existence/types, the PostgreSQL adapter,
and required extension/index prerequisites with actionable errors. Keep model
declaration usable during migration/bootstrap commands; perform schema checks
at an explicit validation point or first use after migrations, as decided below.

`search_data` validation tests must cover existing and missing columns, string
and symbol keys, generated columns, an empty table, and a method requiring real
association data. Never invent missing fields, read every record, or infer a
stable schema from a random first row. Missing-field errors should name the
model and columns, recommend the appropriate migrations, and explain that Ruby
values returned by `search_data` are not persisted by Tinkick.

Exit evidence: migration instructions resolve a failing validation case; schema
refresh after a migration clears stale validation state; model reloads do not
duplicate registration. Error types and new public APIs have RBS signatures.

### 2. First vertical search slice

Implement `Model.search` keyword and fluent forms, literal terms, match-all,
selected fields, scalar filters, sort, limit/offset, lazy results and SQL counts.
Use the model connection pool and database role. Bind values, validate and quote
identifiers, and escape TINQL separately. Preserve model primary keys; never
expose `ctid` as application identity.

Load only the requested page and compute counts independently in SQL. Keep
scoring in the TIN scan query; prove stable pagination under tied scores. Explicitly
resolve the legacy 10,000 default versus bounded application pagination before
choosing a different default. Include default-scope/tenant isolation tests.

Exit evidence: fixture-backed tests against real TIN demonstrate matching,
ranking, filters, counts, insert/update/delete visibility, rollback behavior,
safe handling of SQL/TINQL special characters, and genuine index use. A SQL mock
or an ordinary PostgreSQL FTS index cannot satisfy this gate.

### 3. Compatibility breadth

Add the remaining filters, result wrappers, pagination aliases, eager loading,
projection, chain mutation semantics, highlights and SQL aggregations in small
behavior/test pairs. Cover smart facets, NULL/array semantics and per-field
matching. Investigate fuzzy/phrase/prefix behavior and ranking options against
the pinned upstream baseline before marking them compatible.

Exit evidence: run shared application-level contract examples against Searchkick
and Tinkick in separate processes/bundles. Compare IDs, result interfaces and
documented semantics; classify numeric relevance differences separately. Keep
explicit expectations for intended differences and actionable failures for
unsupported features. Do not add upstream Searchkick as a runtime dependency.

### 4. Migration and release readiness

Publish the supported API matrix, complete migration examples, known semantic
gaps, index maintenance guidance and a sample Rails application. Add multi-model
search and ecosystem features only after their prerequisites are settled.

Exit evidence: representative Rails application migration succeeds with no
Elasticsearch connection; real TIN tests cover concurrency and cleanup in the
designated test database; representative plans/latencies are recorded; selected
Ruby/Rails CI versions pass. No production readiness claim from boot tests alone.

## Migration guidance to develop

A missing `display_name` field can be supplied by an ordinary `text` column
maintained by the application, or a stored generated column for an immutable
expression over the same row. For example, a future application migration can
create a full name from first/last name columns and a TIN index over that field.
The gem must not translate arbitrary Ruby method bodies into generation SQL.

[PostgreSQL generated columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html)
cannot reference other rows or use subqueries, and their expressions must use
immutable functions. Association-derived values therefore need an ordinary
column with application-owned synchronization or another explicitly designed
database mechanism. Generated columns are not a solution for arbitrary joins.
Use explicit `STORED` in migration examples, and test against the deployed
PostgreSQL version rather than relying on a version-dependent default.

Distinguish database `REINDEX` (physical index maintenance after analysis
changes, for example) from Searchkick's data-import `.reindex`. The former may
be necessary operationally; Tinkick will not implement the latter as data copy.

## Decisions before implementation

1. **How `search_data` exposes field names:** existing methods return values from
   instances and may traverse associations or vary keys by record. Resolve when
   and on which instance validation runs, and what to require when it cannot
   discover keys safely. A declared `searchable`/`filterable` field list can be
   validated without reading rows, but must not silently bypass `search_data`.
2. **Compatibility loading:** decide whether Tinkick supplies a `Searchkick`
   constant alias automatically or through an explicit compatibility require.
   Detect coexistence with the actual Searchkick gem. Do not overwrite it.
3. **Removed lifecycle calls:** decide whether legacy `.reindex`, callback
   controls and refresh calls raise migration guidance or selected calls are
   documented no-ops. There is no reindexing implementation in either case.
4. **Analysis contract:** determine the supported policy for default stemming,
   language/synonyms and fuzzy controls that have no proven native equivalent.
   Never silently accept an option that changes intended retrieval semantics.
5. **Visibility:** direct SQL cannot evaluate an arbitrary Ruby `should_index?`.
   Specify its migration to SQL scopes/columns and reconcile default-scope,
   inheritance, tenant and `unscope` behavior before exposing it.
6. **Index ownership and results:** settle index naming/lookup, schema validation
   cache invalidation, the portable `response`/`hits` shape, and `load(false)`
   projections without any external documents.

These are implementation questions, not additional work included in the
initial scaffold. Resolve them before exposing the dependent public behavior.

## Implementation progress

The scaffold is committed. The real integration harness now verifies the
designated database before Rails migrations and exercises TIN with transactional
fixtures. Separate commits implement scalar filter translation, literal/phrase
query compilation, unloaded attribute wrappers, and the extension installer.
RBS uses a pinned maintained Rails signature collection with concrete corrections
for the Rails 8 APIs used by these features.

These internal pieces do not yet provide `Model.search`. Query execution and
per-column index migration generation are the next increments. Public model
registration, lazy relations/results, default analysis/fuzziness, and the broader
compatibility contracts remain unfinished. Native capability observations and
adapter implementation status are recorded separately in the compatibility docs.

## Test environment and documentation status

Local connection settings already exist in `.envrc` / `dev.ejson`, with standard
PostgreSQL environment variables. Use `tinkick_development` for development
and `tinkick_test` for real database/TIN tests, as specified in AGENTS.md.
Never mock or stub PostgreSQL, TIN, or Active Record behavior. Do not log
connection values or use the development database as a disposable test database.
Before integration DDL, identify and verify the dedicated test connection,
database name, extension version and cleanup boundary. Integration tests should
fail clearly when explicitly requested without TIN; they must not silently
substitute PostgreSQL built-in full-text search.

Integration checks now connect and migrate only the dedicated test database. Outline status:
not applicable; no Outline integration is configured. Customer-facing impact:
README and local compatibility/migration planning docs only; no supported
search feature is advertised as already available.
