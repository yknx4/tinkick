# Conversion scoring implementation contract

This is the remaining implementation plan, not an available public feature.
The baseline is Searchkick 6.1.2, commit
`93e901a75b11a25101668a616e006b158251b16e`.

## Data and normalization

Both model declarations describe application-owned query/count hashes. Persist
them in JSONB columns or generated columns; Tinkick must not execute `search_data`
to import values or maintain a second copy. Existing `search_data` validation
continues to check column names only.

Legacy `conversions` transforms each hash entry into a nested query/count record.
The query uses a keyword analyzer: the entire query string is one value, normally
lowercased, without ordinary word splitting or accent folding. Each matching
entry contributes its integer count, and entries are summed. Case-sensitive
model analysis removes lowercasing. Optional `stem_conversions` requires a
separate verified analysis implementation; it cannot silently use ordinary TIN
word analysis. Sources:
[record transformation](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/record_data.rb#L55-L59),
[analyzer](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L37-L40),
[mapping](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/index_options.rb#L364-L374).

`conversions_v2` keeps a hash, lowercases keys unless case-sensitive, replaces
`.` with `*`, and sums normalization collisions. The query selects the similarly
normalized term and uses a linear rank-feature contribution multiplied by
`factor` (default one). The SQL adapter should use counts directly rather than
reproduce Lucene rank-feature quantization; exact score parity is not the target.
Sources: [key transformation](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/record_data.rb#L61-L78),
[query options and scoring](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L645-L680).

## Query composition

- Legacy `conversions` uses explicit fields or the model fields; `false` disables
  it. `conversions_term` replaces the search term for conversion matching.
- V2 accepts a field or `{field:, term:, factor:}`. `true`/nil field selects the
  model's v2 fields. The nested `term` option precedes `conversions_term`.
- To permit migration, model-level legacy conversions disable default v2
  scoring unless the query explicitly requests v2. Their model field names must
  be distinct.
- Contributions add to base relevance before existing numeric/conditional/
  recency multiplier groups. They do not change text-match membership.
- Match-all queries do not apply conversion scoring, even with an override
  conversion term. Similarity queries have a separate upstream branch.

Sources: [legacy options](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L616-L643),
[insertion into the query](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L416-L435),
[score composition](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/query.rb#L583-L613).

## Small implementation sequence

1. Verify count coercion, missing values, invalid count errors, and Unicode
   keyword normalization against the pinned mappings/query behavior. Test
   mixed unrelated queries and normalization collisions on real JSONB rows.
2. Add the SQL contribution helper first. Iterate JSONB pairs on matching rows;
   preserve same-entry query/count correlation. Do not load records to score.
   Warn that per-row JSON processing and final sorting can lose native top-k.
3. Add model/query declarations and fluent options, then compose the contribution
   before existing boosts. Cover disabled/default/explicit migration modes,
   `only`/`except`, counts, aggregations, raw results and cursor/countless pages.
4. Capture `EXPLAIN (ANALYZE, BUFFERS)` with nonmatching query keys and documents.
   Add the public README examples only after the behavior passes.

No optional extension is needed for basic JSONB count lookup and arithmetic.
Any additional normalization dependency must be checked only when that feature
is requested. Count coercion and exact Unicode normalization are still proof
items; this plan does not label them unsupported by TIN.
