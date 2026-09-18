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
- [Testing](docs/reference/testing.md#testing)
- [Reference and unsupported options](docs/reference/compatibility.md#reference-and-unsupported-options)
- [Development, upgrades, and contributing](docs/reference/testing.md#development-upgrades-and-contributing)
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

See the [testing reference](docs/reference/testing.md#testing).

## Reference and unsupported options

See the [reference and unsupported options reference](docs/reference/compatibility.md#reference-and-unsupported-options).

## Development, upgrades, and contributing

See the [development, upgrades, and contributing reference](docs/reference/testing.md#development-upgrades-and-contributing).

## License

[MIT](LICENSE.txt), copyright 2026 yknx4.
