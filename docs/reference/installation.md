# Installation and migration reference

[Back to the guide](../../README.md)

- [Requirements and installation](#requirements-and-installation)
- [Getting started](#getting-started)
- [Migrating alongside Searchkick](#migrating-alongside-searchkick)
- [Datasource and migrations](#datasource-and-migrations)

## Requirements and installation

- Ruby **4.0+**.
- Rails / ActiveRecord **8.0+**, using the PostgreSQL adapter.
- PostgreSQL with the **TIN extension available on the server**. A standard local
  PostgreSQL installation does not include TIN.
- Searchable columns of type `text` or `citext`, with one TIN index per column.

ActiveRecord, `pg`, and `base64` are runtime dependencies. Rails is used for integration and
migration generators; Elasticsearch and OpenSearch clients are not required.
The version ranges permit future Ruby and Rails releases but do not claim they
have already been tested. The CI matrix targets Ruby 4.0 with Rails 8.0 and 8.1.

For a local checkout, add:

```ruby
# Gemfile
gem "tinkick", path: "../tinkick"
```

Then run `bundle install`. The repository can also build an installable gem with
`bundle exec rake build`; publication to RubyGems is a separate release step.

**Rails JSON compatibility:** the verified Rails 8.0.5.1 and 8.1.3.1 releases
need `gem "json", "< 3"` in the application Gemfile. Rails 8.0 encoding and
Rails 8.1 JSONB decoding call interfaces changed by JSON 3. The development
matrix uses JSON 2 for both Rails versions. Tinkick does not patch Rails' JSON
handling; newer Rails releases should be checked before removing this constraint.

## Getting started

Enable TIN through a Rails migration:

```sh
bin/rails generate tinkick:install
bin/rails db:migrate
```

Optional search helpers are opt-in. Install only those used by your application:

```sh
bin/rails generate tinkick:install --unaccent --pg-trgm
```

The default generator enables only TIN. Optional extensions are checked when a
feature uses them; they do not block loading the gem or ordinary TIN searches.
A missing dependency raises `Tinkick::Error` with the required `enable_extension`
Rails migration. If an installation migration already exists, add a new
application migration rather than replacing that migration.

The `--fuzzystrmatch` option is also available for application SQL. Tinkick's
fuzzy matching uses TIN and does not use this extension.

For existing `text` columns, generate the indexes:

```sh
bin/rails generate tinkick:index products name description
bin/rails db:migrate
```

Declare the model:

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:name, :description], default_fields: [:name]
end
```

Search existing records immediately after the migrations:

```ruby
products = Product.search("apple").where(in_stock: true).limit(20)
products.each { |product| puts product.name }

Product.search("red apple", fields: [:name], misspellings: false)
Product.search("*").order(name: :asc).limit(20)
```

`name`, `description`, and `in_stock` in these examples must be real columns.
Do not call `reindex`: the table is already the source of searchable records.
Model declaration does not connect to PostgreSQL or change the schema. The first
search validates the extension, fields, and usable indexes; missing schema
produces migration guidance.

## Migrating alongside Searchkick

Both gems can remain installed while you compare results:

```ruby
class Product < ApplicationRecord
  searchkick searchable: [:name]
  tinkick searchable: [:name]
end

Product.searchkick_search("coffee") # Existing Searchkick backend
Product.tinkick_search("coffee")    # PostgreSQL/TIN backend
```

`tinkick_search` is always explicit. Tinkick installs `search` only if the model
does not already respond to that name, including inherited or nonpublic methods.
Searchkick can install its own alias when declared later, so use the explicit
methods during a transition. Tinkick does not define a `Searchkick` constant,
replace `searchkick`, or share the other gem's configuration.

To choose a different alias, configure it before models declare `tinkick`:

```ruby
# config/initializers/tinkick.rb
Tinkick.search_method_name = :tin_search
# Product.tin_search("coffee") calls Tinkick.
```

Set it to `nil` to create no alias. Existing methods with the chosen name are
preserved, and `tinkick_search` remains available. Changing this setting affects
subsequent declarations; it does not rename aliases already installed on models.

Shared model declaration defaults are also independent of Searchkick:

```ruby
# Set before the affected models declare tinkick.
Tinkick.model_options = {stem: false, match: :word}
```

Explicit model options override these defaults, including `nil`, `false`, and
empty arrays. Defaults pass through the same validation as model declarations;
they do not add database connections during class registration. Replacing the
global defaults hash affects subsequent declarations.

`Tinkick.models` lists the loaded classes that successfully declared `tinkick`,
in declaration order. It is independent of `Searchkick.models`. Subclasses that
inherit a declaration do not add duplicate entries, and inspecting the registry
does not query PostgreSQL or eager-load application models.

Audit the features below before changing callers. Existing Searchkick callbacks,
queues, Redis dependencies, and reindex jobs still belong to Searchkick; retire
them when the old backend is no longer needed. See the
[transition guide](../../docs/migrating-from-searchkick.md) and
[compatibility inventory](../../docs/compatibility.md).

## Datasource and migrations

### `tinkick_search_data` is a schema check

Tinkick calls `tinkick_search_data` on a **new, unsaved model instance** and checks that
its keys are column names. It never serializes the returned values or copies
them to another index.

```ruby
class Product < ApplicationRecord
  tinkick searchable: [:display_name]

  def tinkick_search_data
    { display_name: self[:display_name], in_stock: self[:in_stock] }
  end
end
```

Every key must exist, including fields used only for filtering. A value calculated
by Ruby does not override its stored column. A missing column raises an error
instructing you to add a migration. Methods that require a saved ID, an associated
record, or existing rows must be changed to run safely on a new instance.
The prefixed hook always takes precedence. When Searchkick is in the application
bundle (including `require: false`), Tinkick leaves `search_data` entirely to
Searchkick. Keep that method for Elasticsearch and add `tinkick_search_data`
only if you need Tinkick's explicit schema check; otherwise model columns supply
the field inventory. With no Searchkick in the bundle, `search_data` remains a
fallback when `tinkick_search_data` is absent.

### Computed fields and generated columns

For a same-row expression, a stored generated column can replace computed
`search_data` and provide one combined searchable field:

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

Use an ordinary persisted column when the value needs Ruby logic, associations,
or other rows; your application must maintain that value. PostgreSQL generated
expressions must use immutable functions and cannot contain subqueries or read
other rows. See [generated columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html).

A combined field changes matching semantics: words can match across the original
columns, and phrases can cross their join boundary. Choose that behavior
explicitly instead of treating combination as a transparent index optimization.

### Generator behavior

`tinkick:install` generates extension enablement, not server software installation.
Its rollback refuses to remove a shared extension. Re-running the generator
preserves existing or edited installation migrations.

`tinkick:index TABLE FIELD...` adds separate reversible indexes for existing
columns. It does not create columns, infer Ruby methods, or accept expressions
and schema-qualified names. Duplicate fields and invalid identifiers are rejected.
Review generated migrations through the application's normal deployment process.
For custom names or specialized indexes, write an application Rails migration.
The current model API requires valid, ready, nonpartial, direct-column TIN indexes.

