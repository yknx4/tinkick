# Changelog

## Unreleased

- Add composable `tinql:` / `.tinql(...)` expressions for all documented native
  TINQL operator families, with real TIN/Lead and Rails HTTP coverage. These
  extensions may have no Searchkick equivalent; ordinary search calls are unchanged.

- Keep matching and date bucketing native to TIN/PostgreSQL; remove custom Lucene
  regex, fuzzy-distance, highlight-span, and Elasticsearch date-parser emulation.
- Accept PostgreSQL string regex patterns directly and report unsupported backend
  controls with explicit errors.

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
- Add opt-in countless navigation and typed column cursors for keyset pagination.
- Verify relevance with a varied 268-document corpus and capture real query plans.
- Fix duplicate fixture callbacks and generated-column assertions across Rails 8.0 and 8.1.
