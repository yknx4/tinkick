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
