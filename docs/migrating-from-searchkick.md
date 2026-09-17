# Migration notes

The model API is implemented, while broader compatibility remains in progress.
These notes describe the datasource migration and compatibility policy; consult
the supported feature inventory before switching an application.

## Run both gems during a transition

Keep both gems installed and opt models into Tinkick with `tinkick`:

```ruby
class Product < ApplicationRecord
  searchkick searchable: [:name]
  tinkick searchable: [:name]
end

Product.searchkick_search("coffee") # existing search backend
Product.tinkick_search("coffee")    # PostgreSQL/TIN backend
```

Tinkick always provides `tinkick_search`. It defines `search` only when that
method is not already present, including inherited or application-defined methods.
Use the explicit methods during the transition so declaration order does not
choose your backend accidentally. Searchkick can install its own `search` alias
when declared later; `tinkick_search` remains available in either order.
Tinkick does not define a `Searchkick` constant, a `searchkick` macro, or shared
Searchkick configuration. Existing Searchkick callbacks remain owned by that gem.
Remove those callbacks and reindex jobs only when retiring the old backend.

## Use model columns as the datasource

Tinkick reads the model's PostgreSQL table. PostgreSQL maintains its TIN indexes
as rows change. Once the old backend is retired, remove its data-import/reindex
jobs; Tinkick needs no replacement synchronization pipeline.

`search_data` validates field names on a new model instance against the model schema. It does not
copy its returned values anywhere. If an existing method returns
`{display_name: computed_name}`, the table must contain a `display_name` column
whose persisted value is the desired searchable text. Missing columns must
produce an error with migration guidance.
The method must run safely without saved records or populated associations.
If it cannot, change it to expose the stored field names from a new instance;
Tinkick will not query a sample row to discover a schema.

Use an ordinary column when the value depends on application logic or other
records. The application owns how that value is maintained. For an immutable
expression using only the same row, a stored generated column can keep it current:

```ruby
class AddDisplayNameToProducts < ActiveRecord::Migration[8.0]
  def change
    add_column :products, :display_name, :virtual,
      type: :text,
      as: "coalesce(name, '') || ' ' || coalesce(description, '')",
      stored: true

    add_index :products, :display_name, using: :tin,
      name: "products_display_name_tin"
  end
end
```

Enable the extension first with the `tinkick:install` generator. For columns
that already exist, `tinkick:index products name description` generates one
index per column. Review and run migrations through the application's normal
schema-change process.

[PostgreSQL generated columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html)
cannot contain subqueries or reference other rows. An association-derived field
therefore needs application-maintained storage or an explicitly designed
database mechanism. The gem will not translate arbitrary Ruby methods into SQL.

## Loading and ranking

`load: false` keeps the hash-style result interface for older callers and logs
a warning recommending migration to normal model results. Both modes execute
through Active Record; do not treat it as a query-performance option.

TIN's native ranking is preferred over matching Elasticsearch's scores and tie
ordering exactly. Single-field lexical queries use `tin.score` and dense-term
elision; default relevance ordering without an offset preserves the tested top-k
path. Multi-field lexical queries use `tin.full_score` to avoid an observed
endpoint regression that dropped matching rows. This fallback logs its extra
scoring and sorting cost. See the [regression evidence](tin-api.md#multi-field-scoring-regression-and-fallback)
and [executed query plans](query-plans.md).

Applications that require a deterministic tie order can request explicit sorting,
which may require a sort over matching rows. Supported features with known slow
fallback implementations must log their drawbacks.

Ranking differences do not justify ignoring explicit filters, matching options,
or result interfaces. The compatibility inventory separates those contracts
from numeric score parity and records features that remain unimplemented.
