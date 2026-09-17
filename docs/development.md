# Development and verification

Run repository commands through `direnv exec .`. The local `.envrc` and
`dev.ejson` supply PostgreSQL connection settings; keep their values out of
logs, generated files, and commits.

## Setup

```sh
direnv exec . bundle install
direnv exec . bundle exec rbs collection install
```

Use `tinkick_development` for development and `tinkick_test` for integration
tests. The test helper checks `current_database()` before running any Rails
migrations. It requires a real TIN extension and never substitutes another
search engine. Test-owned tables use the `tinkick_test_` prefix. Rails also
creates its migration tracking tables. Fixture tests run in transactions;
schema migrations remain installed in the dedicated test database.

Do not run separate fixture test processes concurrently against this database.
CI serializes Rails matrix jobs and workflow runs for the same reason. CI needs
repository secrets `PGHOST`, `PGUSER`, `PGPASSWORD`, and optionally `PGPORT`
(default 5432) and `PGSSLMODE` (default require). Credentials must access only
the intended test environment. Local environment files are not uploaded.

## Checks

```sh
direnv exec . bundle exec rake
direnv exec . bundle exec rake build
```

For a targeted integration test, pass its actual path to Ruby with `-Itest` and
`--fail-fast`. Run the touched files through `rubocop -A`, then RuboCop without
autofix, followed by `rake rbs:format rbs:quality steep` before committing.
Keep behavior and its meaningful tests together in a Conventional Commit.

RBS uses the maintained `ruby/gem_rbs_collection` signatures pinned in
`rbs_collection.lock.yaml`. The downloaded `.rbs_collection` is ignored.
Concrete library signatures belong under `sig/`; neither missing framework
types nor type errors should be suppressed as a workaround.

## Verified environment

On 2026-09-17 UTC, read-only connection checks confirmed `tinkick_test` on
PostgreSQL 18.6 with TIN 1.0.2. Rails migrations created TIN indexes and fixture
tests verified matches, insert visibility, and savepoint rollback. These
results establish the integration harness, not complete Searchkick parity.

The endpoint router rejects some standalone function and array-subquery shapes.
Native helper probes using a catalog row as an execution anchor worked. Test
the actual SQL produced by each feature; do not infer support solely from a
PostgreSQL function's presence in the catalog.
