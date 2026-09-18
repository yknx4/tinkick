# API compatibility reference

[Back to the guide](../../README.md)

- [Reference and unsupported options](#reference-and-unsupported-options)

These references cover the feature surface of the [Searchkick 6.1.2 README](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/README.md), including unimplemented APIs and native alternatives.

Status terms used in these references:

- **Available** means implemented in Tinkick. Examples without another label use
  the current API.
- **Not implemented** means the Searchkick option or return interface is missing
  from Tinkick. It does not mean PostgreSQL or TIN cannot do it.
- **Excluded** means an Elasticsearch/OpenSearch transport, document import, or
  index lifecycle API has no direct role in this backend.
- **Native difference** identifies a documented or tested engine behavior.
- **Recipe** means application-owned SQL or ActiveRecord code, with its own
  return shape and behavior. A recipe is not a compatible Tinkick API.

## Reference and unsupported options

The current model declaration accepts `searchable`, `default_fields`, `match`,
the `word_start`/`word_middle`/`word_end` and `text_start`/`text_middle`/`text_end`
field declarations, `case_sensitive`, `special_characters`, `filterable`, `highlight`, and `stem: false`.
It also accepts `conversions`/`conversions_v1`, `conversions_v2`, and
`stem_conversions: false` for native JSONB conversion ranking.
The public search accepts `fields`, `where`, `order`, `limit`, `offset`, `page`,
`per_page`, `padding`, `match`, `operator`, `misspellings`, `load`, `total_entries`,
`countless`, `keyset`, `after`, `aggs`, `smart_aggs`, `includes`,
`model_includes`, `scope_results`, `block`, `exclude`, `select`, `highlight`,
`boost_by`, `boost_where`, `boost`, `boost_by_recency`, `tinql`,
`conversions`, `conversions_v1`, `conversions_v2`, and `conversions_term`.
Use the [guide and topic references](../../README.md#reference) for their limits.
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
| `Tinkick::Reranking.rrf` | Available for bounded ordered lists; see [rank fusion](../reranking.md). |
| `tinql:` / `.tinql(...)` | Available as [TINQL-exclusive extensions](../tinql.md), with no promise of Searchkick equivalents. |
| `multi_search`, `models`, model boosts | Not implemented; separate queries or explicit SQL combination. |
| Scroll/deep-paging configuration | Excluded backend APIs; use bounded column cursors or SQL batches. |
| BigDecimal serialization rules | No JSON document conversion: PostgreSQL column types govern stored precision. |
| Mongoid | Unsupported integration; Tinkick requires ActiveRecord with PostgreSQL. |
| Searchjoy, Autosuggest, Kaminari, will_paginate, Apartment | Not bundled or claimed fully compatible; verify each integration explicitly. |

See [the compatibility inventory](../../docs/compatibility.md) for the wider API target,
[TIN evidence](../../docs/tin-api.md) for verified native behavior, and
[the implementation plan](../../docs/plan.md) for remaining work. “Not implemented” is
not a promise of a release date and should not be relabeled a TIN limitation.
