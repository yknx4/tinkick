# PostgreSQL and Lead in CI

CI uses [PlanetScale Lead](https://github.com/planetscale/lead), a PostgreSQL
extension intended for local development and testing. Each Rails matrix job
starts its own `tinkick_test` database. No PlanetScale connection or repository
database secrets are required. Local `.envrc` and `dev.ejson` remain unchanged.

## Image and cache

[`docker/lead/Dockerfile`](../docker/lead/Dockerfile) pins PostgreSQL 18.6 and
Rust 1.96.0 images by digest, cargo-pgrx 0.19.1, and Lead commit
`1abf2364b6407c330ac6986e595a92c373c9a1f6` from [Lead PR #13](https://github.com/planetscale/lead/pull/13). PostgreSQL is a prebuilt official
image: even a cold build does **not** compile PostgreSQL. Its matching server
headers and explicit `pg_config` let cargo-pgrx compile the Lead extension.
Only the packaged extension and license are copied into the runtime image.

The [workflow](../.github/workflows/ci.yml) imports and exports the GitHub Actions
BuildKit cache with `scope=postgres-lead` and `mode=max`. This retains intermediate
layers, including the Rust tooling and compiled Lead, rather than only the final
runtime layers. Both Rails jobs build the same image and share this cache.
The build context contains only `docker/lead`; gem, test, and documentation
edits do not invalidate the compilation layers or expose local secrets.
Ruby dependencies separately use `ruby/setup-ruby`'s Bundler cache.

An unchanged Apple container rebuild reused **every build layer**, including
cargo-pgrx installation and Lead compilation. The image manifest remained
`sha256:7cf0f5913a817f478660c2acd60a5d8ca681581175c1a84d2e312d138b8105cd`
on arm64. This verifies local BuildKit reuse; GitHub cache restoration still
needs a remote workflow run. GitHub may evict caches, and a cold first run or
changed image/toolchain pin can rebuild Lead. See the
[Docker cache backend documentation](https://docs.docker.com/build/cache/backends/gha/).

## Local checks with Apple container

Apple container is the local runtime; GitHub's Ubuntu runners use Docker.
Start the Apple container service if needed, then build and run:

```sh
direnv exec . container system start
direnv exec . container build --cpus 6 --memory 8G --progress plain \
  --tag tinkick-lead:local docker/lead
direnv exec . container run --detach --name tinkick-lead-check \
  --cpus 4 --memory 4G --publish 127.0.0.1:55432:5432 \
  --env POSTGRES_DB=tinkick_test --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD=tinkick-ci-only tinkick-lead:local
direnv exec . container exec tinkick-lead-check \
  pg_isready -h 127.0.0.1 -U postgres -d tinkick_test
```

Run the test command after `pg_isready` reports that the server accepts
connections. These process-local overrides select Lead without replacing the
existing direnv connection settings:

```sh
direnv exec . env PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres \
  PGPASSWORD=tinkick-ci-only PGSSLMODE=disable TINKICK_TEST_BACKEND=lead \
  bundle exec rake coverage TESTOPTS='--fail-fast --seed=2091'
direnv exec . container stop tinkick-lead-check
```

The password above is only for the disposable local/CI database. Tests verify
`current_database()` before migrating. The first Rails migration enables `tin`
on a fresh database; optional extensions are installed by their existing test
migrations. CI checks TCP readiness, prints database logs on failure, and removes
its test container and volumes when the job ends.

## Temporary Lead exclusions

Lead is not a substitute for production TIN performance validation. Its lossy
bitmap scan and heap rechecks do not implement production TIN's custom scan or
top-k execution. Eleven tests therefore stop immediately before their
production-specific plan assertions when `TINKICK_TEST_BACKEND=lead`; preceding
portable assertions still run. The original ten passed against real TIN, with 77
assertions and no skips. The additional TINQL test verifies boosted proximity
retains production top-k; see the [captured plan](tinql.md#query-plans).

On 2026-09-22, all 42 previously excluded tests were run against a fresh
PostgreSQL 18.6 / Lead PR #13 database with `TINKICK_TEST_BACKEND` unset:
**42 tests, 147 assertions, 25 failures, one error, no skips**. Sixteen tests
passed and were removed from the exact exclusion list:

- All six weighted SQL `tin.full_score()` binding tests.
- All nine scoped/CTE composition and catalog ranking/grouping binding tests.
- The wildcard field-boost isolation test.

The remaining **26 exact exclusions** are listed with their reasons in
[`test/support/lead_failures.rb`](../test/support/lead_failures.rb). No gem
behavior or test assertions were changed to accommodate Lead.

| Reproduced difference at the pinned Lead revision | Exact tests excluded |
| --- | ---: |
| Custom index case/accent/tokenizer/long-token settings are not respected during operator rechecks | 16 |
| Multi-field scoring does not reproduce the expected combined field scores | 6 |
| Fuzzy field-boost scoring does not reproduce the expected ranking | 1 |
| Small visible-row corpora return zero scores for common terms | 3 |

The custom long-token fuzzy test still raises an invalid-query error; the other
25 exclusions fail assertions. Production scan/top-k exclusions remain because
Lead does not implement those production execution paths. These local tests
establish correctness coverage, not production performance.

The exclusions apply only when `TINKICK_TEST_BACKEND=lead`. Running the same
suite against the existing PlanetScale connection without that variable retains
every assertion. The original 31 exclusions passed against PlanetScale TIN 1.0.2:
211 assertions, no failures, errors, or skips. When updating Lead, run its full coverage suite with
`TINKICK_TEST_BACKEND` unset to revisit both the known failures and production
plan differences. Remove each resolved failure from the list; do not extend it
without reproducing and explaining the new failure. Ordinary application
behavior and the 90% library coverage requirement remain checked in CI.

## Local verification, 2026-09-22

Ruby 4.0.1 / Rails 8.1.3.1 / PostgreSQL 18.6 / Lead `1abf2364`:
**1,002 tests, 5,694 assertions, no failures or errors, 37 skips**.
The skips are 26 exact functional limitations and 11 production-plan checks.
Line coverage is **98.02% (2,773 / 2,829)**. Rails 8.0 and remote CI were not
rerun for this local check.

After building the pinned image, the full verification command used the
disposable database on port 55433:

```sh
direnv exec . env PGHOST=127.0.0.1 PGPORT=55433 PGUSER=postgres \
  PGPASSWORD=tinkick-ci-only PGSSLMODE=disable TINKICK_TEST_BACKEND=lead \
  bundle exec rake coverage TESTOPTS='--fail-fast --seed=2091'
direnv exec . bundle exec rubocop -A test/support/lead_failures.rb
direnv exec . bundle exec rubocop test/support/lead_failures.rb
direnv exec . bundle exec rake rbs:format rbs:quality steep
```

RuboCop and RBS formatting/validation passed. Steep exited zero and reported
no type errors, but also logged internal `RuntimeError` exceptions while
checking the unchanged `lib/tinkick/aggregations.rb`; that is a type-checking
coverage gap, not a clean Steep result. No library code or signatures changed.
The generated coverage artifact is `coverage/index.html` (ignored by Git).
No production performance measurement or EXPLAIN ANALYZE was performed;
this change updates only the test backend pin and its verified exclusions.

## Local verification, 2026-09-17

| Runtime | Tests | Assertions | Failures / errors | Skips | Line coverage |
| --- | ---: | ---: | --- | ---: | --- |
| Ruby 4.0.1 / Rails 8.1.3.1 / Lead | 915 | 5,183 | 0 / 0 | 41 | 98.03% |
| Ruby 4.0.1 / Rails 8.0.5.1 / Lead | 915 | 5,183 | 0 / 0 | 41 | 98.03% |

Both full runs used seed 2091 and JSON 2; their 41 skips comprise the 31 exact
failures above and ten production-plan checks. The suite includes the real Rails
HTTP application, varied relevance data, and fixed 10,000-record corpus. Coverage
is 2,589 / 2,641 executable library lines. These local Lead results are not
production TIN performance measurements or a completed remote CI run.

The Rails 8.0 run used the isolated matrix Gemfile described in
[development](development.md), adding
`BUNDLE_GEMFILE=/private/tmp/tinkick-rails-8.0.Gemfile JSON_VERSION='< 3'` to
the coverage command above. Quality and packaging checks passed:

```sh
direnv exec . env ASDF_GOLANG_VERSION=1.26.4 actionlint .github/workflows/ci.yml
direnv exec . bundle exec rubocop -A test/support/backend.rb test/support/lead_failures.rb
direnv exec . bundle exec rake rbs:format rbs:quality steep rubocop build
```

The generated gem is `pkg/tinkick-0.1.0.alpha.1.gem`; SimpleCov writes
`coverage/index.html`. Both artifacts are ignored by Git. Local environment
files, tests, and coverage data are excluded from the gem.
