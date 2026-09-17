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
The stress and relevance corpora share a table but use different fixture paths.
Rails caches fixture sets without their paths, so the stress test clears that
cache before setup and after teardown. Preserve both boundaries when changing
the corpus harness; otherwise test order can substitute the wrong dataset.
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

Checkpoint at code commit `ba2f3fe` (2026-09-17): Ruby 4.0.1 / Rails 8.1.3.1
passed `bundle exec rake coverage TESTOPTS='--seed=2078'`: **646 tests, 4,167
assertions, no failures, errors, or skips**, with **98.00% line coverage**
(2,506 / 2,557 executable lines). This includes the fixed 10,000-record stress
test and took 708 seconds against the remote test database.
`rake rbs:format rbs:quality steep rubocop build` passed: 52 type-checked files
and 124 Ruby files with no offenses. The subsequently added highlight EXPLAIN
script also passed scoped RuboCop. The generated
`pkg/tinkick-0.1.0.alpha.1.gem` includes all four migration templates and their
shared SQL template, without local secrets, test files, or coverage artifacts.

The first seed-2078 run exposed Rails reusing the stress fixture set for the
relevance corpus. Commit `ba2f3fe` fixes the cache boundaries; both corpus orders
passed in one process before rerunning the full suite. The earlier checkpoint
at `5cb5c66` passed 537 tests / 3,341 assertions with 97.82% coverage under its
own test order.

A separate Rails 8.0.5.1 / JSON 2 run at the earlier `5409f2f` checkpoint passed
**82 tests and 565 assertions** for
date parsing, aggregations, public facets, association loading, JSONB search,
two-edit words, phrase options, whole-field matching, and the 10,000-record stress
test. This was a targeted compatibility run, not the full Rails 8.0 suite.
A second Rails 8.0.5.1 / JSON 2 run at `ba2f3fe` passed **32 tests and 192
assertions** for public native/refined/SQL highlights, portable responses, date
histogram formats, and offsets. This also was targeted, not the full Rails 8.0
suite. These are local results; remote CI was not run. Later feature commits
still need their own targeted checks and a final coverage gate.

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
