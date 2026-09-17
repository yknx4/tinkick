# Changelog

## Unreleased

- Add the Ruby 4 / Rails 8+ gem scaffold, development checks, and compatibility research.
- Add a fixture-backed test harness against the dedicated PostgreSQL/TIN database.
- Compile literal/phrase terms and scalar filters against actual model columns.
- Add attribute wrappers for unloaded results and a Rails TIN extension generator.
- Execute ranked, page-limited queries and independent SQL counts with real TIN.
- Generate reversible TIN index migrations for existing text columns.
- Add an internal full-field highlighting helper with Searchkick-style tags and optional HTML encoding.
- Preserve keycap emoji in literal queries and support explicit native fuzzy controls.
- Add `tinkick` model registration, schema checks, and lazy chainable searches.
- Preserve existing `search` methods and coexist with the actual Searchkick gem.
- Use native TIN scoring/top-k, default distance-one typos, and warn on legacy unloaded results.
- Verify persisted generated search fields with real Rails migrations and updates.
- Add an actual Rails application with Faker Tolkien records and HTTP search tests.
