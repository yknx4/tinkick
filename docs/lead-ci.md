# PostgreSQL and Lead in CI

CI uses [PlanetScale Lead](https://github.com/planetscale/lead), a PostgreSQL
extension intended for local development and testing. Each Rails matrix job
starts its own `tinkick_test` database. No PlanetScale connection or repository
database secrets are required. Local `.envrc` and `dev.ejson` remain unchanged.

## Image and cache

[`docker/lead/Dockerfile`](../docker/lead/Dockerfile) pins PostgreSQL 18.6 and
Rust 1.96.0 images by digest, cargo-pgrx 0.19.1, and Lead commit
`0e29dbe5177bb64d027d6afeaa20eb0b46536be6`. PostgreSQL is a prebuilt official
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
top-k execution. Ten tests therefore stop immediately before their
production-specific plan assertions when `TINKICK_TEST_BACKEND=lead`; preceding
portable assertions still run. All ten passed against real TIN, with 77
assertions and no skips.

The first complete Lead run at the pinned revision reported 915 tests,
5,259 assertions, 24 failures, seven errors, and ten plan skips. The user
approved temporarily excluding the **31 exact failing tests**, without changing
gem behavior to accommodate Lead. The complete method names and per-test
reasons are in [`test/support/lead_failures.rb`](../test/support/lead_failures.rb).
No class, feature, or future test is excluded by pattern.

| Verified difference at the pinned Lead revision | Exact tests excluded |
| --- | ---: |
| Operator heap rechecks use default analysis instead of custom index case/accent/tokenizer/long-token settings; this also prevents a truncated-token highlight test from finding its row | 16 |
| Multi-field scores bind only one indexed field expression | 5 |
| Fuzzy score collection uses the input token rather than its matching expansion | 1 |
| `tin.full_score()` fails to bind in the single-branch weighted CTE query shapes | 6 |
| Lead's common-term elision returns zero for the small visible-row corpus used by three raw-result score tests | 3 |

Source evidence is in Lead's pinned
[operator recheck](https://github.com/planetscale/lead/blob/0e29dbe5177bb64d027d6afeaa20eb0b46536be6/postgres/src/operator.rs),
[scoring and planner binding](https://github.com/planetscale/lead/blob/0e29dbe5177bb64d027d6afeaa20eb0b46536be6/postgres/src/score.rs), and
[common-term scoring policy](https://github.com/planetscale/lead/blob/0e29dbe5177bb64d027d6afeaa20eb0b46536be6/postgres/src/bm25.rs).
The weighted CTE errors are reproduced; the precise planner rewrite responsible
has not been isolated. Passing multi-branch weighted tests remain enabled.

The exclusions apply only when `TINKICK_TEST_BACKEND=lead`. Running the same
suite against the existing PlanetScale connection without that variable retains
every assertion. All 31 excluded tests passed against PlanetScale TIN 1.0.2:
211 assertions, no failures, errors, or skips. When updating Lead, run its full coverage suite with
`TINKICK_TEST_BACKEND` unset to revisit both the known failures and production
plan differences. Remove each resolved failure from the list; do not extend it
without reproducing and explaining the new failure. Ordinary application
behavior and the 90% library coverage requirement remain checked in CI.

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
