# Concern refactor verification

Verified locally on 2026-09-22 with Ruby 4.0.1 and real TIN 1.0.2 in
`tinkick_test`. This refactor separates the highest-complexity aggregation,
TINQL, and model declaration methods into small methods and seven
`ActiveSupport::Concern` modules. It preserves validation order and messages,
defaults, SQL, result shapes, and the existing model extension mechanism.

## Complexity and duplication

Measured with Flog 4.9.4 and Flay 2.14.4 against `lib/` using their default
settings. Method extraction redistributes complexity; it does not remove all
the underlying work.

| Metric | Before | After |
| --- | ---: | ---: |
| Highest method Flog score | 180.4 | 101.4 |
| Average method Flog score | 15.7 | 14.6 |
| Total Flog score | 5,734.7 | 5,785.6 |
| Flay duplication score | 655 | 525 |
| Flay groups | 13 | 11 |
| TINQL compiler Flog score | 155.0 | 74.2 |
| Model declaration Flog score | 137.7 | 80.8 |

Aggregation dispatch now separates option validation from execution; date,
numeric, and range operations separate query construction from result shaping.
The duplicated TINQL quantity validation and model field-name validation share
their existing rules. Other Flay similarities remain where the code represents
different validation rules or explicit public option forwarding.

## Behavioral verification

The before/after run used the same seed and passed **279 tests and 1,485
assertions** on each implementation, with no failures, errors, or skips.
Characterization tests cover nested TINQL syntax, literal escaping, conversion
alias precedence, and exact error messages when multiple options are invalid.
Existing real-database tests cover aggregation variants, scopes, counts,
ranking, pagination, and production TIN top-k plan assertions.

```sh
direnv exec . bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2209"]); paths = Dir["test/integration/*aggregation*_test.rb", "test/integration/*histogram*_test.rb", "test/integration/model*_test.rb"] + %w[test/tinql_test.rb test/tinql_search_test.rb test/tinql_rails_app_test.rb test/model_options_test.rb test/model_registry_test.rb]; paths.sort.each { |path| require_relative path }'
```

A local differential probe compared 2,544 TINQL inputs with a saved copy of the
original compiler: both generated strings and exception classes/messages
matched. A real-database comparison of 12 aggregation cases matched exact
payloads and SQL, including query order and count: 19 queries per implementation
with the Active Record query cache disabled. Cases included terms, filters,
metrics, duplicate range keys, numeric histograms, timezone-aware date ranges,
calendar/fixed histograms, bounds, keyed results, and an empty scope. Probe
records were rolled back.

Public instance-method names and parameter lists also matched the original
`Aggregations`, `Tinql`, and `Model` implementations. Concern helpers remain
private.

After the type-checking adjustments, a final focused aggregation rerun passed
**54 tests and 346 assertions**, with no failures, errors, or skips:

```sh
direnv exec . bundle exec ruby -Itest -e 'ARGV.replace(["--fail-fast", "--seed", "2209"]); %w[test/integration/aggregations_test.rb test/integration/histograms_test.rb test/integration/date_histograms_test.rb test/integration/date_histogram_formats_test.rb].each { |path| require_relative path }'
```

RuboCop, RBS formatting/validation, Steep, and gem building pass. The original
Steep run had four internal crashes involving string-keyed record inference.
Named row types and explicitly typed keyed-bucket construction allow the
refactored code to be checked without these crashes or suppressions.

```sh
direnv exec . bundle exec rake quality
direnv exec . bundle exec rake rbs:format rbs:quality steep
direnv exec . bundle exec rubocop lib/tinkick/aggregations.rb lib/tinkick/aggregations lib/tinkick/tinql.rb lib/tinkick/tinql lib/tinkick/model.rb lib/tinkick/model test/tinql_test.rb test/model_options_test.rb test/integration/aggregations_test.rb
direnv exec . bundle exec rake build
```

## Performance and limits

This is a maintainability change, not a performance optimization. A warm local
compiler benchmark used five samples of 20,000 nested compilations per version,
varying execution order. Median time was 164.04 ms before and 167.88 ms
after: about 2.3% higher, or 0.19 microseconds per compilation in this sample.
SQL parity establishes unchanged database work for the compared cases; no
database latency improvement is claimed.

The full test suite, full coverage gate, Rails 8.0 matrix, and remote CI were
not rerun. No runtime dependencies, migrations, public options, or customer
workflows changed. Customer-facing documentation and Outline need no update.

Local artifacts are in ignored `tmp/refactor/`: before/after test and quality
logs, `compiler-parity.json`, `sql-parity.json`, `api-parity.json`, probe scripts, and type-check
logs. The build is `pkg/tinkick-0.1.0.alpha.1.gem`; package inspection confirmed
all 14 concern/signature files are present and test, temporary, and coverage
files are excluded.
