# Development and verification

Run repository commands through `direnv exec .`. The local `.envrc` and
`dev.ejson` supply PostgreSQL connection settings; keep their values out of
logs, generated files, and commits.

## Setup

```sh
direnv exec . bundle install
direnv exec . bundle exec rbs collection install
```

The Rails 8.0 matrix uses `JSON_VERSION='< 3'`. Rails 8.0.5.1's encoder passes
`quirks_mode`, which JSON 3 removed; the integration checkpoint reproduced that
failure. Rails 8.1.3.1 JSONB decoding also fails with JSON 3's positional-argument
change, so both matrix entries use JSON 2. The Gemfile exposes `JSON_VERSION` for
these dependency combinations, and CI resolves each combination separately.
Applications on the verified Rails 8.0/8.1 releases should likewise constrain
`json` below 3 until compatible encoding and decoding are verified on a newer
Rails release. Tinkick does not patch Rails.

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
direnv exec . bundle exec rake coverage
direnv exec . bundle exec rake build
```

The default task and `coverage` enforce at least 90% line coverage across all
`lib/**/*.rb`, including generators. SimpleCov does not merge stale runs or hide
unloaded production files. Reports are written to ignored `coverage/`. Targeted
test commands run without the global coverage threshold; use the full coverage
task for the final gate.

For a targeted integration test, pass its actual path to Ruby with `-Itest` and
`--fail-fast`. Run the touched files through `rubocop -A`, then RuboCop without
autofix, followed by `rake rbs:format rbs:quality steep` for final verification.
Commit small behavior/test pairs progressively using Conventional Commits.
Record regressions and fixes in follow-up commits; do not hold unrelated completed
work until the entire suite is perfect or rewrite the development history.

RBS uses the maintained `ruby/gem_rbs_collection` signatures pinned in
`rbs_collection.lock.yaml`. The downloaded `.rbs_collection` is ignored.
Concrete library signatures belong under `sig/`; neither missing framework
types nor type errors should be suppressed as a workaround.

## Verified environment

Checkpoint at commit `5409f2f` (2026-09-17): Ruby 4.0.1 / Rails 8.1.3.1
passed `bundle exec rake coverage`: **373 tests, 2,251 assertions, no failures or
skips**, with **97.71% line coverage** (1,494 / 1,529 executable lines).
`rake rbs:format rbs:quality steep rubocop` passed: 46 type-checked files and
88 Ruby files with no offenses. The gem built successfully with all three
migration templates and without local secrets or test files.

A separate Rails 8.0.5.1 / JSON 2 run passed **82 tests and 565 assertions** for
date parsing, aggregations, public facets, association loading, JSONB search,
two-edit words, phrase options, whole-field matching, and the 10,000-record stress
test. This was a targeted compatibility run, not the full Rails 8.0 suite.
These are local results; remote CI was not run. Later feature commits still
need their own targeted checks and a final coverage gate.

On 2026-09-17 UTC, read-only connection checks confirmed `tinkick_test` on
PostgreSQL 18.6 with TIN 1.0.2. Rails migrations created TIN indexes and fixture
tests verified matches, insert visibility, and savepoint rollback. These
results establish the integration harness, not complete Searchkick parity.

The endpoint router rejects some standalone function and array-subquery shapes.
Native helper probes using a catalog row as an execution anchor worked. Test
the actual SQL produced by each feature; do not infer support solely from a
PostgreSQL function's presence in the catalog.

## Rails application and Faker data

`test/dummy` is a Rails application with a searchable Tolkien character model,
HTML view, JSON endpoint, and real controller requests. Its ERB fixtures use
`Faker::Fantasy::Tolkien.character`, `.location`, `.race`, and `.poem`, with a
fixed seed and restoration of Faker's previous random generator. The 64 records
are repeatable synthetic combinations, not assertions about Tolkien's canon.

```sh
direnv exec . bundle exec ruby -Itest test/rails_app_test.rb --fail-fast
```

Its table and four TIN indexes are created by the shared Rails migration harness
in `tinkick_test`; writes made by individual tests roll back. The HTTP tests
assert both the stored values and actual TIN SQL. They do not fake search results
or stub Active Record, PostgreSQL, or TIN.

The router rejects the dynamic PL/pgSQL used by Rails' optional fixture foreign
key audit. The dummy app has no foreign keys and explicitly disables that audit;
this setting does not alter the gem or consuming applications. Changes that add
associations to this app must add real foreign-key validation coverage.
