# 079 CLI Database Path And No Workflow Arg

## Goal

Remove the positional `path-to-workflow.yml` CLI argument and add an explicit optional database path flag. The normal startup command should no longer imply that a workflow file is the primary runtime contract.

Target CLI shape:

```text
symphony [--port <port>] [--logs-root <path>] [--database-path <path>]
```

## Context

The product direction is database/Web managed configuration. File-backed split packages still matter as import/export artifacts and initial local files, but the CLI should not accept a workflow YAML path as the main startup selector.

Today the CLI supports:

```text
symphony [--logs-root <path>] [--port <port>] [path-to-workflow.yml]
```

That makes `workflow.yml` look like a runtime-level input even though Settings and SQLite are now the product control plane. Database location is currently controlled by environment/config instead of an ordinary startup flag, which makes local development and alternate database files less direct.

## Scope

- Remove the positional workflow path argument from `CLI.evaluate/2`.
- Remove explicit file-mode startup from the public CLI.
- Add `--database-path <path>` as an optional CLI flag.
- Wire `--database-path` to the same runtime setting currently used by `SYMPHONY_DATABASE_PATH`.
- Update CLI usage text to:
  - `Usage: symphony [--logs-root <path>] [--port <port>] [--database-path <path>]`
- Keep `--port <port>` behavior for enabling the Web dashboard/API.
- Keep `--logs-root <path>` behavior unchanged.
- Decide default workflow source after removing the positional file argument:
  - CLI startup should use database-backed workflow source.
  - Local `workflow.yml` / `profiles.yml` may remain an initialization seed when no active database workflow exists, matching current dashboard-first behavior.
- Reject any extra positional argument as usage error.
- Update tests and docs so startup commands no longer pass `./workflow.yml`.

## Non-Goals

- Do not remove the split package file format.
- Do not remove import/export plans for `workflow.yml` and `profiles.yml`.
- Do not change the Web Settings data model.
- Do not change SQLite migrations or schema.
- Do not add a new workflow file path flag.
- Do not change `--logs-root` semantics.

## Acceptance Criteria

- [x] `CLI.evaluate([])` starts in database workflow source mode instead of defaulting to `./workflow.yml` file mode.
- [x] `CLI.evaluate(["--port", "4000"])` starts in database workflow source mode and sets the server port.
- [x] `CLI.evaluate(["--database-path", "tmp/symphony.db"])` sets the configured database path to the expanded path and starts in database workflow source mode.
- [x] `CLI.evaluate(["--logs-root", "tmp/logs", "--database-path", "tmp/symphony.db"])` sets both paths and starts normally.
- [x] `CLI.evaluate(["workflow.yml"])` returns the usage error.
- [x] `CLI.evaluate(["--port", "4000", "workflow.yml"])` returns the usage error.
- [x] README and user docs contain no startup examples that pass `./workflow.yml` to `bin/symphony`.
- [x] User-facing docs explain that `workflow.yml` / `profiles.yml` are package files for seed/import/export, not CLI startup arguments.

## Test Plan

- Update `test/symphony_elixir/cli_test.exs` for:
  - default database startup
  - `--port`
  - `--database-path`
  - combined `--logs-root` and `--database-path`
  - rejection of positional workflow args
- Add or update config tests for database path override if the config layer does not already expose a direct setter.
- Search active docs for `bin/symphony` examples and remove positional `./workflow.yml`.
- Run:
  - `mise exec -- mix test test/symphony_elixir/cli_test.exs`
  - `mise exec -- mix test`
  - `mise exec -- mix lint`
  - `mise exec -- mix build`
  - `git diff --check`

## Implementation Notes

- The CLI currently receives runtime dependencies through `runtime_deps/0`; add a `set_database_path` dependency to keep `CLI.evaluate/2` testable without mutating global config directly.
- Prefer reusing the existing database path config mechanism rather than introducing a parallel path variable.
- Removing the positional path means `OptionParser.parse/2` should only accept `{opts, [], []}` as the valid shape.
- Keep local split package loading behind the database startup bootstrap path if it is still used as a seed. The CLI should not expose that seed path as an argument.
- This plan pairs naturally with 078: remove the guardrails acknowledgement first or in the same implementation pass, then simplify the CLI surface to port/logs/database-path.
