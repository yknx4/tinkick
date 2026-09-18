# Tinkick

Searchkick-style search for Ruby and Rails, backed by
[PlanetScale TIN](https://planetscale.com/docs/postgres/search). Your model's
PostgreSQL table is the datasource. PostgreSQL maintains the search indexes when
rows change; there is no second document store to synchronize.

**Status: alpha.** Core search includes word, phrase, partial and exact matching,
native typo tolerance, SQL/JSONB filters, relevance boosts, highlighting, facets,
model/raw-row results, and page, keyset and countless pagination. The priority is
practical Rails search with native TIN performance, not complete Searchkick API
parity. This guide covers the feature surface of
the [Searchkick 6.1.2 reference README](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/README.md),
including features that still need native integration or a different application design.

Implementation stays within TIN, PostgreSQL, and available extensions. Backend
differences are part of the API contract: unsupported explicit controls raise
clear errors instead of invoking custom Lucene or Elasticsearch emulation.

Throughout this guide:

- **Available** means implemented in Tinkick. Examples without another label use
  the current API.
- **Not implemented** means the Searchkick option or return interface is missing
  from Tinkick. It does not mean PostgreSQL or TIN cannot do it.
- **Excluded** means an Elasticsearch/OpenSearch transport, document import, or
  index lifecycle API has no direct role in this backend.
- **Native difference** identifies a documented or tested engine behavior.
- **Recipe** means application-owned SQL or ActiveRecord code, with its own
  return shape and behavior. A recipe is not a compatible Tinkick API.

## Contents

- [Requirements and installation](docs/reference/installation.md#requirements-and-installation)
- [Getting started](docs/reference/installation.md#getting-started)
- [Migrating alongside Searchkick](docs/reference/installation.md#migrating-alongside-searchkick)
- [Datasource and migrations](docs/reference/installation.md#datasource-and-migrations)
- [Querying](docs/reference/querying.md#querying)
- [Results and metadata](docs/reference/results.md#results-and-metadata)
- [Filtering](docs/reference/filtering.md#filtering)
- [Matching and analysis](docs/reference/matching.md#matching-and-analysis)
- [Boosting, conversions, and personalization](docs/reference/ranking.md#boosting-conversions-and-personalization)
- [Autocomplete and suggestions](docs/reference/matching.md#autocomplete-and-suggestions)
- [Aggregations and facets](docs/reference/aggregations.md#aggregations-and-facets)
- [Highlighting](docs/reference/results.md#highlighting)
- [Similar items, geospatial, and vector search](docs/reference/ranking.md#similar-items-geospatial-and-vector-search)
- [Pagination and large result sets](docs/reference/results.md#pagination-and-large-result-sets)
- [Models, scopes, and tenancy](docs/reference/querying.md#models-scopes-and-tenancy)
- [Indexing and synchronization](docs/reference/operations.md#indexing-and-synchronization)
- [Advanced SQL and debugging](docs/reference/operations.md#advanced-sql-and-debugging)
- [Performance and consistency](docs/reference/operations.md#performance-and-consistency)
- [Deployment and operations](docs/reference/operations.md#deployment-and-operations)
- [Testing](#testing)
- [Reference and unsupported options](#reference-and-unsupported-options)
- [Development, upgrades, and contributing](#development-upgrades-and-contributing)
- [License](#license)

## Requirements and installation

See the [requirements and installation reference](docs/reference/installation.md#requirements-and-installation).

## Getting started

See the [getting started reference](docs/reference/installation.md#getting-started).

## Migrating alongside Searchkick

See the [migrating alongside searchkick reference](docs/reference/installation.md#migrating-alongside-searchkick).

## Datasource and migrations

See the [datasource and migrations reference](docs/reference/installation.md#datasource-and-migrations).

## Querying

See the [querying reference](docs/reference/querying.md#querying).

## Results and metadata

See the [results and metadata reference](docs/reference/results.md#results-and-metadata).

## Filtering

See the [filtering reference](docs/reference/filtering.md#filtering).

## Matching and analysis

See the [matching and analysis reference](docs/reference/matching.md#matching-and-analysis).

## Boosting, conversions, and personalization

See the [boosting, conversions, and personalization reference](docs/reference/ranking.md#boosting-conversions-and-personalization).

## Autocomplete and suggestions

See the [autocomplete and suggestions reference](docs/reference/matching.md#autocomplete-and-suggestions).

## Aggregations and facets

See the [aggregations and facets reference](docs/reference/aggregations.md#aggregations-and-facets).

## Highlighting

See the [highlighting reference](docs/reference/results.md#highlighting).

## Similar items, geospatial, and vector search

See the [similar items, geospatial, and vector search reference](docs/reference/ranking.md#similar-items-geospatial-and-vector-search).

## Pagination and large result sets

See the [pagination and large result sets reference](docs/reference/results.md#pagination-and-large-result-sets).

## Models, scopes, and tenancy

See the [models, scopes, and tenancy reference](docs/reference/querying.md#models-scopes-and-tenancy).

## Indexing and synchronization

See the [indexing and synchronization reference](docs/reference/operations.md#indexing-and-synchronization).

## Advanced SQL and debugging

See the [advanced sql and debugging reference](docs/reference/operations.md#advanced-sql-and-debugging).

## Performance and consistency

See the [performance and consistency reference](docs/reference/operations.md#performance-and-consistency).

## Deployment and operations

See the [deployment and operations reference](docs/reference/operations.md#deployment-and-operations).

## Testing

Use a real PostgreSQL database with TIN. Do not mock PostgreSQL, TIN, or
ActiveRecord to claim search compatibility. For an application with migrated
search columns and fixtures:

```ruby
class ProductSearchTest < ActiveSupport::TestCase
  test "search sees the current database row" do
    product = Product.create!(name: "Red Apple", description: "Fresh fruit")
    assert_includes Product.search("red apple", misspellings: false).map(&:id), product.id
  end
end
```

No search callback switch, `refresh`, or reindex trait is needed. Rails fixture
transactions provide test isolation. For Minitest outside Rails or RSpec, set up
the real connection/schema and transaction cleanup explicitly. Factory Bot creates
ordinary rows; do not add Searchkick-style reindex callbacks to its factories.
Parallel workers need separate databases or another verified isolation strategy,
not Searchkick index suffixes on one shared table.

### The repository's real Rails application

The [dummy application](test/dummy) serves HTML and JSON through a controller and
registered Tinkick models. Its fixture set includes 64 deterministic synthetic
Tolkien characters generated with `Faker::Fantasy::Tolkien` and a separate
268-document search corpus: 256 varied multi-sentence records plus 12 controls
for phrase order, term frequency, document length, field boundaries, and typos.
These are synthetic test records, not assertions about Tolkien's canon.

```sh
direnv exec . bundle exec ruby -Itest test/rails_app_test.rb --fail-fast
```

The HTTP tests exercise real stored values, rendered and JSON output, filters,
bounded pages, injection-like search text, native typo matching, and visibility after
writes, plus countless navigation and cursor traversal. The development matrix
uses Ruby 4.0.1, Rails 8.0.5.1 and 8.1.3.1, with JSON 2.21.2. Remote CI has not
been run. See the tests and [development guide](docs/development.md) for current
verification commands.

A separate fixed **10,000-document** corpus uses Faker Tolkien seed 314159,
9,992 varied documents across fantasy/travel/food/technical topics, and eight
explicit controls. Its stress test passed **26 assertions** covering ranking,
unrelated text, phrases, typos, facets, keyset/countless pagination, and updates:

```sh
direnv exec . bundle exec ruby -Itest test/stress_test.rb --fail-fast
```

[Executed stress query plans](docs/query-plans.md#fixed-10000-document-corpus)
show TIN top-k for relevance/countless queries, a primary-key scan for the
match-all cursor case, and SQL aggregation over the complete corpus. These are
local regression and execution-plan results, not complete Searchkick parity or
production throughput claims.

### CI and database isolation

Repository tests use `tinkick_test`; development uses `tinkick_development`.
Standard PostgreSQL environment variables come from direnv locally. The harness
checks `current_database()` before Rails migrations, uses test-owned table names,
and requires TIN or Lead installed on the server. Keep `.envrc` and `dev.ejson`
unchanged. Separate fixture processes must not share the same test database.

Each CI matrix job runs an isolated PostgreSQL 18.6 server with
[PlanetScale Lead](https://github.com/planetscale/lead), without PlanetScale
secrets; the jobs can run in parallel. GitHub uses Docker/Buildx, while local
reproduction uses Apple's `container` tool. PostgreSQL comes from a pinned
prebuilt image. Intermediate Rust/Lead layers use the GitHub Actions cache with
`mode=max`; a warm local build reported all layers `CACHED`.

Exactly 31 observed failing tests are temporarily excluded on Lead
pending upstream fixes. Production-only plan assertions are gated separately;
both remain active against PlanetScale TIN. See [Lead CI](docs/lead-ci.md) for
the limitations and reproduction steps, and [the workflow](.github/workflows/ci.yml)
for configuration. This is not a claim that remote CI has completed.

## Reference and unsupported options

The current model declaration accepts `searchable`, `default_fields`, `match`,
the `word_start`/`word_middle`/`word_end` and `text_start`/`text_middle`/`text_end`
field declarations, and `stem: false`.
It also accepts `conversions`/`conversions_v1`, `conversions_v2`, and
`stem_conversions: false` for native JSONB conversion ranking.
The public search accepts `fields`, `where`, `order`, `limit`, `offset`, `page`,
`per_page`, `padding`, `match`, `operator`, `misspellings`, `load`, `total_entries`,
`countless`, `keyset`, `after`, `aggs`, `smart_aggs`, `includes`,
`model_includes`, `scope_results`, `block`, `exclude`, `select`, `highlight`,
`conversions`, `conversions_v1`, `conversions_v2`, and `conversions_term`.
Use the detailed sections above for their limits.
Unknown keywords or methods are not compatibility no-ops.
Features proven unsupported by TIN raise `Tinkick::NotImplementedError` with an
explanation naming the backend limitation. Unfinished Tinkick features must not
be mislabeled as TIN limitations; invalid inputs remain validation errors.

The following reference maps less common upstream options to their current status:

| Searchkick API or configuration | Status / replacement |
| --- | --- |
| `searchable`, `default_fields`, `match` | Available within the supported modes/types. |
| `filterable` | Accepts field lists and validates columns/JSONB path roots lazily. Does not limit filters or create indexes; add appropriate PostgreSQL indexes through migrations. |
| `unscope`, `inheritance`, query `type` | Not implemented as Searchkick options; define explicit model scopes and test the intended STI/tenant behavior. |
| Global `model_options` | `Tinkick.model_options` supplies defaults for subsequent declarations; explicit model values override them. |
| `search_method_name` | `Tinkick.search_method_name` selects the alias for subsequent declarations; `nil` disables alias creation. Existing methods are preserved and `tinkick_search` remains available. |
| `index_name`, dynamic names, prefix/suffix | Excluded index identity API; use explicit database/schema/table tenancy. |
| Custom `search_document_id` | Excluded document identity API; results use the model's single primary key. |
| `mappings`, `merge_mappings`, `settings` | Excluded server configuration DSL; use migrations and native index options. |
| `case_sensitive`, `special_characters` | Implemented as native index-policy validation and SQL text normalization; migrate indexes to match explicit declarations. |
| `language`, stemming options | `stem: false` is accepted. `stem: true`, `language`, `stemmer`, `stem_exclusion`, and `stemmer_override` raise `Tinkick::NotImplementedError` with migration guidance. |
| `search_synonyms`, synonym file/reload | Not implemented; application synonym storage/expansion is a recipe. |
| `conversions`, `conversions_v1`, `conversions_v2`, `conversions_term` | Native JSONB conversion ranking with field selection, term overrides and v2 factors; see the conversion contract. |
| `stem_conversions` | Nil/false accepted. Stemming requests raise `Tinkick::NotImplementedError`; persist normalized keys and provide their lookup term. |
| `exclude` | Available across selected fields; exact phrase negatives with mode-specific matching. |
| `suggest`, `similar`, `emoji` | Not implemented; see the corresponding recipes. |
| `locations`, `geo_shape`, `knn` | Not implemented; design explicit PostGIS/pgvector integration where available. |
| `callbacks`, queues, job priorities/parent jobs | Excluded synchronization configuration. |
| Import batch size, resume, partial/bulk reindex | Excluded document import API; update real data with application jobs/migrations. |
| Routing, request parameters, opaque IDs | Excluded transport API; use SQL filters, database routing, and Rails instrumentation. |
| `timeout`, `search_timeout`, `client_options` | Not implemented; configure database timeouts/pooling. |
| `includes`, `model_includes` | Available; preload only visible model results. |
| `scope_results` | Available; filters the ranked page with an extra query and warning. |
| `select`, source filtering, `reselect` | Available for top-level columns and nested JSON source filtering; model loading remains complete. |
| `only`, `except` | Available for query-option selection/removal; these do not select model columns. |
| `body`, `body_options`, body-mutating blocks | Elasticsearch DSL is excluded. Use `block:` or a Ruby block to transform the Active Record relation with SQL/Arel. |
| `search_index`/`searchkick_index` inspection | Not implemented; use PostgreSQL catalogs and TIN helpers. |
| Index refresh, clean/promote/store/remove, queue inspection | Excluded external-index lifecycle. |
| Global search | Available with an explicit `model:`; preserves generic search-method ownership. |
| `multi_search`, `models`, model boosts | Not implemented; separate queries or explicit SQL combination. |
| Scroll/deep-paging configuration | Excluded backend APIs; use bounded column cursors or SQL batches. |
| BigDecimal serialization rules | No JSON document conversion: PostgreSQL column types govern stored precision. |
| Mongoid | Unsupported integration; Tinkick requires ActiveRecord with PostgreSQL. |
| Searchjoy, Autosuggest, Kaminari, will_paginate, Apartment | Not bundled or claimed fully compatible; verify each integration explicitly. |

See [the compatibility inventory](docs/compatibility.md) for the wider API target,
[TIN evidence](docs/tin-api.md) for verified native behavior, and
[the implementation plan](docs/plan.md) for remaining work. “Not implemented” is
not a promise of a release date and should not be relabeled a TIN limitation.

## Development, upgrades, and contributing

Keep the existing `.envrc` and `dev.ejson` local. They supply development/test
connection settings, are excluded from Git and the gem, and must not be replaced
or printed during setup. Requiring the gem and unit/boot checks do not require a
live database; integration tests do.

```sh
direnv exec . bundle install
direnv exec . bundle exec rbs collection install
direnv exec . bundle exec rubocop -A Gemfile tinkick.gemspec Rakefile Steepfile lib test
direnv exec . bundle exec rake rbs:format rbs:quality
direnv exec . bundle exec rake
direnv exec . bundle exec rake build
```

`rake` runs the combined fail-fast Minitest suite, RuboCop, RBS validation, and
Steep. `rake build` produces `pkg/tinkick-0.1.0.alpha.1.gem`. `Gemfile.lock` is local
and ignored so supported dependency ranges can be exercised. CI uses Bundler
directly rather than a local `.envrc`.

Contributions should pair behavior changes with meaningful tests against real
TIN, keep RBS and RuboCop synchronized, and use reviewable Conventional Commits.
Report the Ruby/Rails/PostgreSQL/TIN versions, reproducible query, schema, and
actual plan when reporting a search bug; omit credentials and private records.

Upgrading from Searchkick 5 or 6 is a backend migration, not merely a gem version
change. Audit model options, derived fields, query methods, result consumers,
background jobs, and relevance expectations. The supported keyword/fluent APIs
cover part of Searchkick 6's builder interface. Migrate conversion columns with
Rails and select v2 explicitly as described above; Searchkick's index upgrade
tasks are not Tinkick procedures. Follow
[CHANGELOG.md](CHANGELOG.md) for Tinkick changes and rerun application search
contracts before upgrading an alpha release.

Thanks to the Searchkick project for the API this gem aims to preserve, and to
the PlanetScale TIN team for the PostgreSQL search engine and reference material.

## License

[MIT](LICENSE.txt), copyright 2026 yknx4.
