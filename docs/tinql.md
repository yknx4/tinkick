# TINQL extensions

These are **TINQL-specific features** and may have no equivalent in Searchkick.
They use native TIN execution, with the usual Tinkick results, filters, ranking,
aggregations, highlighting, pagination, and Active Record hooks.

```ruby
Product.tinkick_search(tinql: { and: ["coffee", "beans"] }).where(in_stock: true)
Product.tinkick_search("coffee").tinql(and_not: ["beans", "decaf"])
```

Strings inside expressions are literal phrases. Hashes compose expressions;
`and` and `or` accept nonempty arrays, and `and_not` accepts exactly two operands.
An ordinary search term and a `tinql:` expression combine with `AND` within each
selected search field. Misspelling options affect the ordinary term only.
`.tinql(...)` replaces the previous expression; `.tinql(nil)` removes it.

For explicit native syntax, use `raw:`:

```ruby
Product.tinkick_search(tinql: { raw: 'coffee NEAR/2 beans' })
```

Raw input is bound as SQL data but deliberately interpreted as TINQL. Keep query
structure application-controlled. Native syntax errors come from PostgreSQL.
Whole-field SQL match modes (`exact`, `text_start`, `text_middle`, `text_end`)
cannot be combined with `tinql:`. Existing highlighting analysis restrictions apply.

See the [native language reference](https://planetscale.com/docs/postgres/search/tinql).

## Phrases and proximity

```ruby
Product.search(tinql: { near: ["coffee", "beans"], distance: 2 })
Product.search(tinql: { then: ["coffee", "beans"], distance: 0 })
Product.search(tinql: { phrase: "fresh coffee beans", slop: 2 })
Product.search(tinql: { phrase: ["fresh", nil, "beans"] })
Product.search(tinql: { phrase: ["fresh", ["coffee", "cocoa"], "beans"] })
```

`near` accepts either word order; `then` preserves it. Both take exactly two
expressions and require `distance`, the maximum extra words between them
(`0` means adjacent). `slop` allows extra gaps in an ordered phrase. In phrase
arrays, `nil` means one arbitrary word and an inner array gives alternatives
at that position. Strings remain literal, including `_`, `[` and `]`.

Limit the width of a matching span:

```ruby
Product.search(tinql: {
  within: { near: ["coffee", "beans"], distance: 5 }, words: 4
})
```

## Token patterns, ranges, and boosts

| Expression | Meaning |
| --- | --- |
| `{ term: "coffee" }` | Literal term/phrase; equivalent to a plain string |
| `{ all: true }` | Match all documents |
| `{ wildcard: "cof?ee*" }` | Native token wildcard: `?` one character, `*` zero or more |
| `{ matches: "cof+ee.*" }` | Native TINQL full-token regex, not Ruby or PostgreSQL regex |
| `{ range: ["coffee", "tea"] }` | Inclusive dictionary range; `nil` opens either bound |
| `{ fuzzy: "cofee", distance: 1, prefix: 1 }` | Native edit distance with a fixed prefix; both default to `1` |
| `{ boost: "coffee", factor: 3 }` | Multiply the expression's relevance; factor must be `0..10000` |

Patterns and ranges apply to **tokens**, not whole column values. Keep ordinary
column comparisons and PostgreSQL regex filters in `where`. Regex patterns use
the index's normalized dictionary spelling and native escaped whitespace.
Wildcard patterns and range bounds must be single native terms without query
delimiters; use `raw:` when writing more specialized native syntax.

```ruby
Product.search(tinql: { or: [
  { boost: { phrase: "coffee beans" }, factor: 3 },
  { fuzzy: "cofee", distance: 1, prefix: 0 }
] })
```

## Minimum-match groups

```ruby
Product.search(tinql: { at_least: ["coffee", "beans", "roasted"], count: 2 })
Product.search(tinql: { at_least: ["coffee", "beans", "roasted"], percent: 50 })
Product.search(tinql: { any_of: ["coffee", { phrase: "hot chocolate" }] })
Product.search(tinql: { all_of: ["coffee", "beans"] })
```

`at_least` requires either a positive integer `count` or an integer `percent`
from 1 to 100. Groups accept nested expressions and must not be empty.
