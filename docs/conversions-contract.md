# Native conversion scoring

Conversion ranking reads application-owned JSONB columns and adds counts to the
native relevance score in PostgreSQL. It preserves the selectors and defaults
below; it does not reproduce Elasticsearch mappings, analyzer behavior or score
quantization.

## Public controls

The selector contract follows Searchkick 6.1.2. The linked pinned source has
identical conversion selection and scoring code.

| Control | Behavior |
| --- | --- |
| Model `conversions:` / `conversions_v1:` | Declares legacy fields. `conversions_v1` aliases and takes precedence over `conversions` when both keys exist, at model and query level. |
| Query `conversions:` | Omitted/nil uses model legacy fields; a string, symbol, or array replaces them. `false` or `[]` disables. `true` is not a model-default selector. |
| Model `conversions_v2:` | Declares one or multiple v2 fields. A field cannot also be declared for legacy conversions. |
| Query `conversions_v2:` | `false` disables; a string/symbol selects one field; `true` selects all model v2 fields. A hash accepts `field`, `term`, and `factor`. An array is not a multiple-field query selector. |
| V2 hash `field` | Missing/nil/true selects all model v2 fields; a string/symbol selects one field. |
| Term override | Legacy uses `conversions_term` or the search term. V2 uses its hash `term`, then `conversions_term`, then the search term. Nil/false overrides fall through; the selected value uses `to_s`. Match the entire key, including spaces and punctuation. |
| Factor | V2 uses `factor` or `1`; zero skips v2 scoring, JSONB validation and iteration. Finite nonnegative numbers and numeric strings are accepted. The factor applies to each selected field. Legacy has no factor option. |

With no model legacy fields, an omitted/nil query v2 option enables declared v2
fields. When both versions are declared on the model, an omitted/nil query v2 option
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
model table; `search_data` remains a physical-column sanity check and never
imports or transforms values. Conversion fields must be real nonarray JSONB
columns. Explicit query selectors may name columns beyond the model declaration;
validation occurs when scoring is compiled. Repeated fields are deduplicated.

```ruby
class AddConversionCountsToProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :products, :conversion_counts, :jsonb, default: {}, null: false
  end
end

class Product < ApplicationRecord
  tinkick searchable: [:name], conversions_v2: [:conversion_counts]
end

product.update!(conversion_counts: {"red apple" => 5, "apple.pie" => 3})
Product.search("apple", conversions_v2: {term: "red apple", factor: 0.5})
```

Both versions use literal whole JSONB keys, including dots. With the model's
`case_sensitive: true`, scoring performs direct exact-key lookup. Otherwise,
PostgreSQL `lower(key) = lower(term)` compares entries and sums matching case
variants. Accents and whitespace remain significant. TIN index tokenization,
`special_characters` and stemming settings do not transform conversion keys.

`stem_conversions: nil` or `false` is accepted; requests for stemming raise
`Tinkick::NotImplementedError`. Persist application-normalized keys and pass the
corresponding `conversions_term` when needed. This differs from the upstream
[keyword analyzer](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L37-L40)
and its [stem removal](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L316-L325).

## Native contribution

The selected counts contribute to each matching row before the existing
multiplier groups:

```text
(TIN relevance + sum(legacy counts) + sum(v2 counts * factor))
  * existing sum-group multiplier * existing product-group multiplier
```

Scoring sums across selected fields, entirely in SQL. It does not broaden the
lexical result set or change counts and aggregation membership. This follows
Searchkick's
[optional scoring clauses and function composition](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L584-L614),
Elasticsearch's [default function-score multiplication](https://www.elastic.co/docs/reference/query-languages/query-dsl/query-dsl-function-score-query),
and its [linear rank-feature contribution](https://www.elastic.co/docs/reference/query-languages/query-dsl/query-dsl-rank-feature-query).

Missing keys, SQL NULL and JSON null contribute zero. Matching values use native
PostgreSQL numeric casts, so numeric strings work and malformed strings, booleans,
objects or arrays fail. Negative and nonfinite matching counts raise a database
error. Unrelated keys are not cast. Factors must be finite and nonnegative;
arithmetic uses native PostgreSQL precision and errors rather than Elasticsearch
Float32 limits. Scores and tie ordering can differ.

The compiler logs that conversion scoring can require sorting matches instead
of native TIN top-k. Case-insensitive lookup also iterates JSONB entries per row.
See the [reproducible conversion plans](conversion-plans.md); small-corpus plans
are evidence about those SQL shapes, not production throughput guarantees.

## Scope

Basic JSONB lookup and arithmetic require no optional extension. Applications
own conversion event tracking, aggregation and updates. Tinkick creates no
analytics tables, jobs or synchronization callbacks; Searchjoy hooks and
Elasticsearch conversion-index upgrade tasks are not provided. Column updates
take effect without reindexing.
