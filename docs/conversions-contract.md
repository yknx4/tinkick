# Conversion scoring plan

Conversion scoring is not yet an available public feature. Its implementation
must use PostgreSQL JSONB lookup and arithmetic, without reproducing Elasticsearch
index mappings, Lucene rank-feature storage, or analyzer internals.

## Public contract to implement

Verified against released Searchkick 6.1.2. The linked pinned source has identical
conversion selection and scoring code.

| Control | Behavior |
| --- | --- |
| Model `conversions:` / `conversions_v1:` | Declares legacy fields. `conversions_v1` aliases and takes precedence over `conversions` when both keys exist, at model and query level. |
| Query `conversions:` | Omitted/nil uses model legacy fields; a string, symbol, or array replaces them. `false` or `[]` disables. `true` is not a model-default selector. |
| Model `conversions_v2:` | Declares one or multiple v2 fields. A field cannot also be declared for legacy conversions. |
| Query `conversions_v2:` | `false` disables; a string/symbol selects one field; `true` selects all model v2 fields. A hash accepts `field`, `term`, and `factor`. An array is not a multiple-field query selector. |
| V2 hash `field` | Missing/nil/true selects all model v2 fields; a string/symbol selects one field. |
| Term override | Legacy uses `conversions_term` or the search term. V2 uses its hash `term`, then `conversions_term`, then the search term. Nil/false overrides fall through. Match the entire key, including spaces and punctuation. |
| Factor | V2 uses `factor` or `1`; zero does not select the default. The factor applies to each selected field. Legacy has no factor option. |

When both versions are declared on the model, an omitted/nil query v2 option
defaults to legacy scoring only. Disabling legacy at query time does not enable
v2 automatically: that default checks the model's legacy declaration. Explicit
`conversions_v2: true` enables v2 without disabling legacy; switching requires
`conversions: false, conversions_v2: true`. An explicit v2 hash also bypasses the
legacy default suppression. Match-all `"*"` skips conversion scoring, even with a
term override. See [query selection](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L617-L681)
and [model declarations](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L364-L383).

Fluent `conversions(value)`, `conversions_v1(value)`, `conversions_v2(value)`, and
`conversions_term(value)` each require one argument and return a clone. Their bang
variants replace the option, reject mutation after loading, and return self.
Repeated v2 hashes replace rather than merge. See [relation methods](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/relation.rb#L135-L172).

## Data ownership

Store query/count hashes in application-owned JSONB columns. Tinkick reads the
model table; search_data remains a physical-column sanity check and never imports
or transforms values.

Use PostgreSQL case folding when case-insensitive lookup is requested. Do not
construct Unicode mapping tables to reproduce Ruby or Lucene versions. Keep
literal JSONB keys, including dots. Applications needing other normalization
should persist it explicitly in their data or an appropriate generated column.
Do not add an Elasticsearch keyword analyzer or stemmer compatibility layer.

`stem_conversions` is a model-only legacy keyword-analyzer setting, off by
default; it does not affect v2 keys. Upstream `stem: false` also removes that
legacy stemmer. Reject requests requiring conversion stemming with
`Tinkick::NotImplementedError` and guidance to persist normalized keys. Do not
reconstruct stemming, custom analyzers, or rank-feature storage. See the pinned
[keyword analyzer](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L37-L40)
and [stem removal](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L316-L325).

## Native contribution

Read the requested JSONB count for each matching row and add its numeric
contribution to relevance before the existing multiplier groups:

```text
(TIN relevance + sum(legacy counts) + sum(v2 counts * factor))
  * existing sum-group multiplier * existing product-group multiplier
```

Sum across selected fields; missing JSONB keys contribute zero. Sum matching
entries when case-insensitive lookup matches multiple keys. Conversion scoring
must not broaden the lexical result set. Preserve same-entry query/count
correlation and keep processing in SQL. This follows Searchkick's
[optional scoring clauses and function composition](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L584-L614),
Elasticsearch's [default function-score multiplication](https://www.elastic.co/docs/reference/query-languages/query-dsl/query-dsl-function-score-query),
and its [linear rank-feature contribution](https://www.elastic.co/docs/reference/query-languages/query-dsl/query-dsl-rank-feature-query).

Prefer direct key lookup; normalization that requires iterating JSONB pairs must
warn about per-row work and loss of native top-k sorting.

Use PostgreSQL numeric conversion and clearly defined missing-value handling.
Document differences instead of reproducing Elasticsearch coercion, Float32
quantization, or ranking internals. Scores may differ.

## Public integration and verification

Keep useful model/query field selection, disabling, term overrides, and factors
where they map directly to this contribution. Reject options requiring unsupported
backend behavior with Tinkick::NotImplementedError and a concrete explanation.
Do not accept options silently.

Test real JSONB rows containing unrelated queries, missing keys, different counts,
case differences, and invalid values. Verify membership remains unchanged while
ranking changes. Cover selector/default transitions, whole-key matching, term
precedence, factors, composition before other boosts, match-all bypass, fluent
mutation rules, result projections, and pagination. Capture EXPLAIN ANALYZE before
documenting performance.

Basic JSONB lookup and arithmetic require no optional extension.
