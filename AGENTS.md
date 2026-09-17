# Tinkick Agent Instructions

This file contains the repository-wide rules for coding agents. Specialist
workflows live in `skills/`; tool-specific overlays should point here instead
of restating shared guidance.

## Instruction Order

1. Follow this file.
4. Use `.github/instructions/` for file-type-specific conventions.

When instructions conflict, prefer the earlier source. Ask before proceeding
when the conflict would change behavior, architecture, rollout, or scope.

## Project Context

Tinkick is a Rails 8 compatible gem for searckick-api compatible search using TIN as backend instead of Elasticsearch. It uses PostgreSQL with [TIN](https://planetscale.com/docs/postgres/search) as the search engine. The gem provides a simple and efficient way to perform full-text search on Rails models using TIN.

It MUST be api compatible with searchkick, with the exception of low level features or reindexing that only make sense for Elasticsearch. It is designed to be a drop-in replacement for searchkick (assuming they are not using features that are specific to Elasticsearch), allowing developers to easily switch from Elasticsearch to TIN without having to change their existing codebase. 

Use rails migrations for any change, migrations should be importable to projects that use this gem. 

Since TIN is still a development feature that is not yet available as a local plugin, there will be 2 databases. 

tinkick_development for development and tinkick_test for testing. The connection parameters will be available in the environment using direnv with standard postgres environment variables.

## Operating Rules

- Keep RBS definitions and RuboCop in sync with the code. Do not disable or ignore violations
  without explicit user approval.
- Ask when intent, architecture, requirements, or rollout choices are unclear.
- Implement the simplest complete solution. Do not add speculative flexibility,
  abstractions, or unrelated cleanup.
- Match nearby patterns and keep logic in the layer that owns it. Classes
  stay thin.
- State material uncertainty before acting.
- Suggest a more durable alternative when it has a clear benefit, but keep it
  separate from the requested change unless the user approves the expanded scope.
- Preserve unrelated user and agent work. Touch and stage only files required by
  the task.
- Run repository commands through `direnv exec .` unless the command must run
  outside the project environment.
- Use Conventional Commits. Keep commits reviewable by pairing coherent behavior
  with its tests; add follow-up commits instead of amending existing work unless
  the user asks otherwise.

## Implementation Workflow

1. Read the surrounding code, relevant instructions, and existing tests.
2. For behavior changes and bug fixes, add or update a failing test first. State
   the blocker if TDD is impractical.
3. Implement the smallest change that satisfies the test.
4. Run formatters and autofixers for touched files before the final test run.
5. Run targeted tests and quality gates for every affected layer.
6. Report changed behavior, exact verification commands, generated artifacts,
   residual risk, and any blocked check.

Do not call work complete while required tests or lint fail. If full coverage is
not possible, make the gap explicit.

## Testing and Quality Gates

Choose the test layer that proves the changed behavior:

- Prefer fixture-backed Minitest under `test/` 
- Combine files for the same runner into one fail-fast invocation.
- Run targeted checks; the full local suite is not expected.

Do not write tests for reversible, low-impact changes that mirror the
implementation. If you do choose to verify your work with tests, make
sure that the tests are meaningful and necessary to verify implementation.

Never ever mock or stub postgres behaviour, TIN behaviour or ActiveRecord behaviour. Use real database and TIN for testing.

Run tests appropriate to the change and complete required checks. Once
those pass, broaden or repeat testing only when new changes, failures,
or unresolved concerns justify it; otherwise, continue toward completing
the task.

For touched Ruby or RBS:

- Run `bundle exec rubocop -A` on touched Ruby files, then rerun RuboCop without
  autofix.
- Add or update meaningful RBS for new or changed public and internally shared
  Ruby APIs.
- Use concrete application and Ruby types. Reserve `untyped` for genuine
  untyped boundaries, not known models or primitives.
- Run `bundle exec rake rbs:format rbs:quality` and the repository Steep check.
  Existing debt belongs only in the explicit debt baseline.
- Use rubocop-shopify config. 

## Architecture and Production Safety

- Use native TIN, PostgreSQL, and available extensions. Do not recreate Lucene
  or Elasticsearch execution engines, parsers, or automata for compatibility;
  document backend dialect differences and use native SQL boolean filters.
- Regex filters accept native PostgreSQL strings only. Do not translate Ruby
  Regexp sources or flags.
- Keep jobs idempotent where practical and choose queues deliberately.
- Never preload a collection merely to count or aggregate it.
- Load only the data currently visible. Tabs, date ranges, toggles, modals, and
  expandable panels should fetch hidden data when it becomes visible.

## Completion Standard

A task is ready only when the affected behavior has appropriate automated
coverage, targeted checks pass, touched Ruby satisfies RuboCop and RBS/Steep
requirements, generated artifacts are reported, and remaining risks are explicit.
For product-visible work, include Outline status and customer-facing docs impact.

## Coding style

You don't need permission for reversible tasks, read-only actions,
reviews or fixes, or anything authorized earlier in this session.
Stop only before: sending anything to a third party, payments,
deletes outside the workspace, permission changes, production
deploys, and merges.

Implement it, run it, inspect the result, fix what fails, and bring
me a reviewable diff. Approval is the last step, not the first.

The user's instructions take precedence over guidelines provided in a
skill. If explicit user instructions conflict with a skill's
instructions, prioritize the user's instructions.

If a skill causes you to ask for permission or confirmation, pause,
leave requested work unfinished, or diverge from the user's intent,
name and link to the exact SKILL.md file you read, quote the relevant
instruction, and briefly explain how it applies.
