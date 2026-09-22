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
migrations. The server must have the `tin` extension files installed, supplied
by PlanetScale TIN or by Lead for isolated CI. Test-owned tables use the
`tinkick_test_` prefix. Rails also creates its migration tracking tables.
Fixture tests run in transactions;
schema migrations remain installed in the dedicated test database.

Do not run separate fixture test processes concurrently against this database.
The stress and relevance corpora share a table but use different fixture paths.
Rails caches fixture sets without their paths, so the stress test clears that
cache before setup and after teardown. Preserve both boundaries when changing
the corpus harness; otherwise test order can substitute the wrong dataset.
Each CI matrix job has its own Lead server and database, so those jobs can run
in parallel without sharing fixtures. CI needs no PlanetScale secrets. Local
`.envrc` and `dev.ejson` remain unchanged and are not uploaded.

## CI with Lead

GitHub Actions uses Docker/Buildx to build PostgreSQL with PlanetScale's
[Lead extension](https://github.com/planetscale/lead). Local reproduction uses
Apple's `container` tool. The image starts from pinned, prebuilt PostgreSQL
18.6; it compiles Lead, not PostgreSQL. GitHub Actions caches intermediate Rust
and Lead build layers with `mode=max`. A repeated local build reported all
layers `CACHED`.

Lead is a non-production implementation for application tests. Exactly 31
observed failing tests are temporarily excluded only when
`TINKICK_TEST_BACKEND=lead`, pending upstream fixes. Production TIN plan
assertions are gated separately because Lead does not implement production
top-k execution. These exclusions do not establish full compatibility; the
default PlanetScale TIN path retains those checks. See [Lead CI](lead-ci.md)
for the exact limitations, cache configuration, and reproduction commands.

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

### Complexity and duplication

```sh
direnv exec . bundle exec rake quality
direnv exec . bundle exec rake flog
direnv exec . bundle exec rake flay
```

Flog reports complexity and Flay reports structural duplication in `lib/`, using
their default scoring and reporting settings. These are advisory reports run
on demand, without arbitrary score gates in CI. Tests and fixtures are outside
the analysis scope. Both gems are development tools, not runtime dependencies
of the published gem.

The [Ruby Sadist page](https://ruby.sadi.st/Ruby_Sadist.html) also lists Heckle.
It is not installed: Heckle requires ParseTree, whose
[upstream documentation](https://github.com/seattlerb/parsetree) marks it
end-of-life because it relies on MRI 1.8 internals. It cannot run on this
project's Ruby 4.0. Mutation testing is therefore not configured.

### Targeted checks and types

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

## Concern organization

`Aggregations` keeps option validation, dispatch, and shared SQL value handling.
Its private aggregation implementations live in `Terms`, `Metrics`, `Ranges`,
`NumericHistograms`, and `DateHistograms` concerns. `Tinql::Expressions` owns
compound expression serialization; `Model::Declaration` owns model declaration
and validation. These use `ActiveSupport::Concern` without callbacks or new
configuration. `Tinkick::Model` retains its existing extension mechanism.

See the [refactor measurements and verification](refactoring.md) for the
behavior-preservation checks and before/after Flog and Flay results.

## Verified environment

Core search checkpoint (2026-09-17, code through `80e223d`): Ruby 4.0.1 with
Rails 8.1.3.1 and 8.0.5.1 / JSON 2 passed the full Lead suite on each version:
**942 tests / 5,329 assertions, zero failures/errors, 98.05% line coverage**
(2,617 / 2,669 executable lines). Each run has the same 31 approved Lead-only
exclusions and ten production-plan skips documented in [Lead CI](lead-ci.md).

The focused production TIN gate passed **89 tests / 513 assertions with no
failures, errors, or skips**. It covers actual Rails HTTP requests, the varied
268-document relevance corpus, the deterministic 10,000-record Faker Tolkien
stress corpus, query execution, page/countless/keyset pagination, and real
Searchkick coexistence. No further main-search defect was found in the code and
test audit. Secondary compatibility options remain documented follow-ups under
the user's practical-search priority; this is not a complete Searchkick parity
claim.

```sh
direnv exec . env -u TINKICK_TEST_BACKEND -u COVERAGE bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "3170"]); %w[rails_app_test relevance_test stress_test integration/query_test integration/countless_test integration/pagination_test integration/keyset_test integration/model_test].each { |name| require_relative "test/#{name}" }'
direnv exec . env PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=tinkick-ci-only PGSSLMODE=disable TINKICK_TEST_BACKEND=lead bundle exec rake coverage TESTOPTS='--fail-fast --seed=2094'
direnv exec . env PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGPASSWORD=tinkick-ci-only PGSSLMODE=disable TINKICK_TEST_BACKEND=lead BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3' bundle exec rake coverage TESTOPTS='--fail-fast --seed=2094'
direnv exec . bundle exec rake rbs:format rbs:quality steep rubocop build
```

RBS/Steep passed; RuboCop inspected 173 Ruby files with no offenses. The generated
gem is `pkg/tinkick-0.1.0.alpha.1.gem`, and coverage is in `coverage/index.html`.
The test-only connection overrides above do not modify `.envrc` or `dev.ejson`.
Remote GitHub CI and gem publication have not been run.

Native scoring and JSONB conversions checkpoint (`083a11b`, 2026-09-17):
Ruby 4.0.1 / Rails 8.1.3.1 passed **103 tests / 590 assertions** in 83 seconds
for conversion queries, fluent controls, model defaults, existing query/relation
behavior and the real Rails HTTP app. The native JSONB helper separately passed
**18 tests / 145 assertions**, including zero-factor SQL identity, nulls, invalid
counts and literal keys. Rails 8.0.5.1 / JSON 2 passed **103 tests / 599 assertions**
in 95 seconds for all tests changed since the native cleanup checkpoint plus
the Rails HTTP app. All these targeted runs had no failures, errors or skips.

```sh
direnv exec . bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2086"]); %w[integration/conversion_search_test integration/conversion_relation_test integration/model_test integration/model_defaults_test integration/query_test integration/query_options_test integration/relation_test rails_app_test].each { |name| require_relative "test/#{name}" }'
direnv exec . bundle exec ruby -Itest test/integration/conversion_scores_test.rb --fail-fast
direnv exec . env BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3' bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2086"]); paths = IO.popen(["git", "diff", "--name-only", "6aad0be..083a11b", "--", "test"], &:read).lines.map(&:strip).grep(/_test\.rb\z/); (paths + ["test/rails_app_test.rb"]).uniq.each { |path| require_relative path }'
direnv exec . bundle exec rake rbs:format rbs:quality steep rubocop build
```

RBS and Steep passed; RuboCop checked 160 Ruby files without offenses. The built
`pkg/tinkick-0.1.0.alpha.1.gem` contains 76 files, including the conversion source
and signature and both migration templates, with no environment, test or coverage
files. The [recency](recency-plans.md) and [conversion](conversion-plans.md)
collectors verified unchanged membership, expected winners/scores and transaction
cleanup before recording real plans. README and local feature documentation are
updated; no Outline publication or remote CI run was performed.

The full coverage suite was not rerun for this checkpoint. Coverage percentages
below apply to their recorded earlier code states, not these new features.

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
