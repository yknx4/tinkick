# Conversion scoring plan

Conversion scoring is not yet an available public feature. Its implementation
must use PostgreSQL JSONB lookup and arithmetic, without reproducing Elasticsearch
index mappings, Lucene rank-feature storage, or analyzer internals.

## Data ownership

Store query/count hashes in application-owned JSONB columns. Tinkick reads the
model table; search_data remains a physical-column sanity check and never imports
or transforms values.

Use PostgreSQL case folding when case-insensitive lookup is requested. Do not
construct Unicode mapping tables to reproduce Ruby or Lucene versions. Keep
literal JSONB keys, including dots. Applications needing other normalization
should persist it explicitly in their data or an appropriate generated column.
Do not add an Elasticsearch keyword analyzer or stemmer compatibility layer.

## Native contribution

Read the requested JSONB count for each matching row and add its numeric
contribution to relevance before the existing multiplier groups. Preserve
same-entry query/count correlation and keep processing in SQL. Prefer direct
key lookup; normalization that requires iterating JSONB pairs must warn about
per-row work and loss of native top-k sorting.

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
ranking changes, and cover result projections and pagination. Capture EXPLAIN
ANALYZE before documenting performance.

Basic JSONB lookup and arithmetic require no optional extension.
