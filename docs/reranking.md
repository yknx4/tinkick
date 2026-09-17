# Reciprocal rank fusion

`Tinkick::Reranking.rrf` combines ordered result lists using their rank positions:

```ruby
first = Product.search("mithril", where: { category: "weapons" }).limit(20)
second = Product.search("dwarven steel").limit(20)
ranked = Tinkick::Reranking.rrf(first, second)
ranked.first(5).map { |entry| entry[:result] }
```

Each entry contains the original `:result` and its fused `:score`. A result at
position `rank` contributes `1.0 / (k + rank)` for that list, with ranks starting
at one and `k: 60` by default. A result absent from a list contributes zero.
Results are deduplicated using Ruby equality and sorted by descending fused
score; equal scores retain first encounter order. Repeated entries within one
list use their last position, matching the pinned Searchkick behavior.

Inputs must provide `to_ary`, as arrays and Tinkick search relations do. Fusion
materializes the supplied lists, so set an appropriate limit on each search.
It does not run additional searches, compute embeddings, or change the native
scores of the original results. A single list and empty lists are supported.

This preserves the public [Searchkick 6.1.2 rank-fusion algorithm](https://github.com/ankane/searchkick/blob/93e901a75b11a25101668a616e006b158251b16e/lib/searchkick/reranking.rb).
