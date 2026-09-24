# Native TINQL form measurements

Captured on **2026-09-23** against `tinkick_development`: PostgreSQL 18.6, TIN
1.0.2. The [JSON artifact](benchmarks/2026-09-23-native-tinql-forms.json)
records every form tried, its match count, and its median timings.

The corpus has 200,000 synthetic documents of 30 words each. Words are drawn
with a skew from a 300,000-word pseudo-word vocabulary, and a few real words are
planted every 97th document. The body has a 48 MB TIN index. Timings are
PostgreSQL's `EXPLAIN ANALYZE` execution times, the median of 7 or 21 interleaved
warm runs. They cover a top-k query (`tin.score` DESC, `LIMIT 20`) and a count.
They exclude Ruby and network time. Do not treat them as production latency.

## Choices

| Use | Forms compared (top-k median) | Chosen |
| --- | --- | --- |
| Default fuzzy | `appl~0:1` 149 ms; `appl~1` 11.8 ms; `appl~2:1` 1.9 ms | Native `term~N`, unless `prefix_length` is given |
| `word_start` | `app*` 3.4 ms; `app TO app🯹…` 3.0 ms (count 20–50% faster) | Term-dictionary range |
| `word_middle`, `word_end` | `*ppl*` ≡ `MATCHES .*ppl.*` (~115 ms); `*ple` ≡ `MATCHES .*ple` (~105 ms) | Wildcard (no native alternative) |
| Punctuated tokens | `CONTAINS don't*` ≡ `MATCHES don't.*` | Wildcard; regex only when the token contains TINQL delimiters |
| Keycap literals | `MATCHES \*` 0.47 ms; `"*️⃣"` 0.25 ms | Quoted phrase |
| Literal, AND, OR | Bare, quoted, `CONTAINS`, implicit AND, `ALL OF`, `[a b]` were equivalent | Unchanged quoted phrases |

Every chosen form returned the same match counts as the form it replaced.

## Range bounds

TIN analyzes range bounds. A bound ending in U+10FFFF, U+FFFF or private-use
characters loses that suffix, so the range collapses to the exact term. Those
first attempts (`experiment1` in the artifact) returned too few matches.
U+1FBF9 (a segmented digit, `Nd`) survives analysis inside a word, and it sorts
after every character that can continue a unicode-tokenized Latin, Greek,
Cyrillic, or digit word. Bounds repeat it up to the index's `max_token_bytes`.
TIN splits longer tokens, so completions that themselves contain U+1FBF9 are
still covered. Range bounds fold case and accents natively, and keyword-like
prefixes such as `TO` or `AND` parse as terms. Tinkick uses ranges only for
`word_start` words on the default unicode tokenizer that leave room for the pad;
other words keep the wildcard.

## Operational warning

A single-character prefix (`a*`, which expands most of the dictionary) terminated
the database connection during a timed run on this endpoint. It also disrupted
a concurrent test run. Either syntax expands the same dictionary range. Keep
autocomplete inputs to two or more characters in applications on large indexes.
