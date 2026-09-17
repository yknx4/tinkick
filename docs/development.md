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

Native-backend cleanup checkpoint (2026-09-17, through `f394548`): Ruby 4.0.1 /
Rails 8.1.3.1 exercised **835 tests / 4,925 assertions** in 1,319 seconds, with
**97.97% line coverage** (2,466 / 2,517 executable lines). The run included the
Rails HTTP application, varied relevance corpus, and fixed 10,000-record stress
dataset. It reported zero assertion failures and one error: an old recursive
JSON filter test still supplied a Ruby `Regexp`, which the native-only API now
rejects. This was not a green full-suite command.

Commit `f394548` changes that test input to a PostgreSQL pattern string. Its
entire seven-test file then passed **7 tests / 36 assertions**, with no failures,
errors, or skips. No library change was needed. The full suite was not repeated
after this test-only correction. Reproduction commands:

```sh
direnv exec . bundle exec rake coverage TESTOPTS='--seed=2082'
direnv exec . bundle exec ruby -Itest test/integration/recursive_json_filter_test.rb --fail-fast --seed 2082
direnv exec . bundle exec rake rbs:format rbs:quality steep
direnv exec . bundle exec rubocop
```

RBS formatting and validation passed; Steep checked 48 library files without
type errors, and RuboCop checked 151 Ruby files without offenses. The corrected
JSON test also passed its own RuboCop autofix and normal checks. Coverage reports
are in ignored `coverage/`. These are local results; remote CI was not run.

The focused Rails 8.0.5.1 / JSON 2 run passed **77 tests / 384 assertions**, with
no failures, errors, or skips, in 119 seconds. It covers native fuzzy matching,
date buckets, highlighting boundaries, PostgreSQL regex and recursive JSON
filters, the Rails HTTP app and relevance corpus, standard date parsing, and
generated installation migrations. This is a targeted matrix check, not the
entire Rails 8.0 suite:

```sh
direnv exec . env BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3' bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2082"]); %w[integration/native_fuzzy_test integration/native_date_histograms_test integration/native_highlight_boundary_test integration/native_fuzzy_highlight_test integration/raw_regexp_filter_test integration/regexp_filter_test integration/recursive_json_filter_test rails_app_test relevance_test aggregation_date_test generators/install_generator_test].each { |name| require_relative "test/#{name}" }'
```

The checkpoint results and commands below describe their named commits. The
native-backend cleanup subsequently removed custom regex, fuzzy-distance,
highlight-span, and date-parsing emulation, including their tests. Historical
commands that name those tests require the cited checkout; they are not current
verification claims.

Recent-query checkpoint at `1b4967d` (2026-09-17): Ruby 4.0.1 / Rails
8.0.5.1 with JSON 2 passed **99 tests / 445 assertions**, no failures, errors,
or skips, in 119 seconds. This covers recency scoring, custom primary keys,
recursive JSON arrays and object existence, enum equality, custom phrase
boundaries/highlights, and operation notifications. Reproduce with:

```sh
direnv exec . env BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3' bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2078"]); %w[recency_boost_test recency_boost_search_test custom_primary_key_filter_test recursive_json_filter_test json_container_filter_test enum_filter_test custom_phrase_spans_test custom_phrase_gap_spans_test custom_phrase_oversized_spans_test custom_phrase_highlight_test instrumentation_test].each { |name| require_relative "test/integration/#{name}" }'
```

The matrix Gemfile is a local verification artifact, with the repository as its
gem source and Rails constrained to 8.0. This is a targeted matrix run, not a
replacement for full coverage. The same functionality has targeted Rails 8.1
checks recorded in its commits. RuboCop passed on changed Ruby; the shared
RBS formatting/validation and Steep checkpoint passed 60 library files.

The package was rebuilt from an immutable `git archive` of `9b9d830`, excluding
concurrent uncommitted work. It contains 85 files and all five `.tt` templates
(four migrations and their shared SQL template), with no environment/secrets,
test, coverage, or Git files. Output: `pkg/tinkick-0.1.0.alpha.1.gem`;
SHA-256 `e701015123bcfc000b039c66d2863b4cf65e325acd9d6db7636a05c1f362ebca`.

Checkpoint at code commit `9abb818` (2026-09-17): Ruby 4.0.1 / Rails 8.1.3.1
passed `direnv exec . bundle exec rake coverage TESTOPTS='--seed=2078'`:
**832 tests, 4,971 assertions, no failures, errors, or skips**, with **97.71%
line coverage** (2,991 / 3,061 executable lines). This includes the actual Rails
application and fixed 10,000-record stress test, and took 876 seconds against the
remote test database. `direnv exec . bundle exec rake rbs:format rbs:quality steep
rubocop` and `direnv exec . bundle exec rake build` passed: 56 type-checked files
and 147 Ruby files with no offenses. The generated
`pkg/tinkick-0.1.0.alpha.1.gem` includes all four migration templates and their
shared SQL template, without local secrets, test files, or coverage artifacts.

An earlier seed-2078 run exposed Rails reusing the stress fixture set for the
relevance corpus. Commit `ba2f3fe` fixes the cache boundaries; both corpus orders
passed in one process before the `ba2f3fe` checkpoint passed 646 tests / 4,167
assertions with 98.00% coverage. The earlier checkpoint at `5cb5c66` passed 537
tests / 3,341 assertions with 97.82% coverage under its own test order.

A separate Rails 8.0.5.1 / JSON 2 run at the earlier `5409f2f` checkpoint passed
**82 tests and 565 assertions** for
date parsing, aggregations, public facets, association loading, JSONB search,
two-edit words, phrase options, whole-field matching, and the 10,000-record stress
test. This was a targeted compatibility run, not the full Rails 8.0 suite.
A second Rails 8.0.5.1 / JSON 2 run at `ba2f3fe` passed **32 tests and 192
assertions** for public native/refined/SQL highlights, portable responses, date
histogram formats, and offsets. This also was targeted, not the full Rails 8.0
suite.

At `9abb818`, Rails 8.0.5.1 / JSON 2 passed **186 tests and 804 assertions** for
all test files added or changed since `ba2f3fe`: field and numeric/JSON boosts,
custom source spans and highlights, date bounds and IANA subday histograms,
model defaults/highlight declarations, and configurable search aliases. This
targeted run took 183 seconds. Its isolated Gemfile sets
`ENV["RAILS_VERSION"] = "~> 8.0.0"` and evaluates this repository's Gemfile:

```sh
direnv exec . env BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3' \
  bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2078"]); IO.popen(["git", "diff", "--name-only", "ba2f3fe..9abb818", "--", "test"], &:read).lines.map(&:strip).grep(/_test\.rb\z/).each { |path| require_relative path }'
```

At `420d78a`, Rails 8.0.5.1 / JSON 2 passed **89 tests and 431 assertions**
for test files added or changed since `9abb818`: filterable declarations,
conditional and legacy boosts, custom phrase spans/highlights, IANA fixed
histograms, and case/accent declarations. The run took 124 seconds with no
failures, errors, or skips:

```sh
direnv exec . env BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3' \
  bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2078"]); IO.popen(["git", "diff", "--name-only", "9abb818..420d78a", "--", "test"], &:read).lines.map(&:strip).grep(/_test\.rb\z/).each { |path| require_relative path }'
```

These are local results; remote CI was not run. The full Rails 8.0 suite has not
been run. Verification applies to the cited checkpoint; subsequent feature
commits need their own targeted checks and a final coverage gate.

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
