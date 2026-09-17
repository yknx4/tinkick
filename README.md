# Tinkick

Tinkick is a gem targeting near drop-in compatibility with
[Searchkick](https://github.com/ankane/searchkick), using
[PlanetScale TIN](https://planetscale.com/docs/postgres/search) and the Rails
model's PostgreSQL table as the datasource.

**Status: scaffold only.** The gem loads and has development checks, but does
not yet implement `searchkick`, `search`, field validation, or migrations.
Do not replace Searchkick in a running application with this version.

## Requirements

- Ruby 4.0 or newer.
- Rails / Active Record 8.0 or newer.
- PostgreSQL with the `tin` extension for future search integration tests and use.
  Ordinary PostgreSQL does not provide TIN by itself.

The gemspec leaves future Ruby and Active Record versions eligible; that is not
a claim that unreleased versions have been tested. CI targets Ruby 4.0 with
Rails 8.0 and 8.1. Rails is a development dependency; Active Record and `pg`
are runtime dependencies.

## Intended compatibility

Existing model declarations and queries should retain their Searchkick names.
This is a future usage target, **not working code in this scaffold**:

```ruby
class Product < ApplicationRecord
  searchkick searchable: [:name]
end

Product.search("coffee").where(in_stock: true).limit(20)
```

Search reads the model's actual columns. There is no separate document store,
data import, synchronization job, or data reindexing. PostgreSQL maintains TIN
indexes as table rows change. Index creation and maintenance belong in explicit
migrations and operational work.

`search_data` is intended as a schema sanity check, not a data producer:
its field names must correspond to database columns. Missing fields must raise
an actionable error asking for migrations. Computed fields need ordinary
persisted columns or suitable PostgreSQL generated columns. Values returned by
Ruby `search_data` will not be copied into search storage.

See the [compatibility inventory](docs/compatibility.md),
[TIN API notes](docs/tin-api.md), and [implementation plan](docs/plan.md).
They identify semantic gaps, including stemming, and decisions still required.

## Development

The existing `.envrc` and `dev.ejson` supply local development/test connection
settings. Keep them local; neither is included in Git or the built gem. This
scaffold does not change their contents. Unit and Rails boot checks do not
connect to PostgreSQL.

The designated databases are `tinkick_development` and `tinkick_test`, using
standard PostgreSQL environment variables supplied through direnv. Future
schema changes must use Rails migrations importable into consuming applications.

Run commands through the project environment:

```sh
direnv exec . bundle install
direnv exec . bundle exec rbs collection install
direnv exec . bundle exec rubocop -A Gemfile tinkick.gemspec Rakefile Steepfile lib test
direnv exec . bundle exec rake rbs:format rbs:quality
direnv exec . bundle exec rake
direnv exec . bundle exec rake build
```

`rake` runs the combined Minitest suite with fail-fast, RuboCop, RBS validation,
and Steep. `rake build` writes `pkg/tinkick-0.1.0.alpha.1.gem`. `Gemfile.lock`
is generated locally and ignored so the library's dependency ranges can be
tested across Rails versions.

CI runs the equivalent Bundler commands directly because it has no local
`.envrc`. The real-TIN integration harness uses the dedicated `tinkick_test`
database and fixture transactions. See [development and verification](docs/development.md)
for CI secrets, database isolation, and the distinction between harness checks
and Searchkick compatibility coverage.

## License

[MIT](LICENSE.txt), copyright 2026 yknx4.
