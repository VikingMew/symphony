# 190 First Run Default YAML Import Prompt

## Goal

When Symphony starts for the first time with no usable database workflow data, detect the checked-in default YAML package files and ask the operator whether to import them into the database.

The prompt must be explicit and skippable. Local `workflow.yml` and `profiles.yml` remain import artifacts/examples, not hidden runtime fallback sources.

## Status

Completed.

## Background

The current runtime model is database-first. If the SQLite database does not exist, or exists but has no active workflow version, Symphony can boot into a setup-required state and the operator can import or create configuration through the UI.

That is correct for production semantics, but it is rough for first local startup because this repository already carries default package files in the expected folder structure:

- `elixir/workflow.yml`
- `elixir/profiles.yml`

Those files are useful starter configuration, but the runtime should not silently read them as authoritative configuration. Completed plans 017, 018, 080, 097, 119, 120, and 132 moved the project away from implicit file fallback and toward explicit database import/save semantics.

The desired behavior is a first-run assist:

- if the database is missing or empty;
- and no active workflow version exists;
- and default YAML package files are present;
- then Symphony asks whether to import the defaults into the database;
- if the operator says yes, import and activate them through the same validated import path used by Settings;
- if the operator says no, continue setup-required without importing;
- if a non-interactive or opt-out flag is set, do not ask.

## Scope

- Define a first-run database state check that distinguishes:
  - no database file yet;
  - database exists but has no workflow versions;
  - database has workflow versions but no active version;
  - database has an active workflow version.
- Detect the repository/package default files using the current folder structure, starting with `workflow.yml` and `profiles.yml` under the runtime working directory or application package root as appropriate for development and release builds.
- Add a startup-time operator prompt only when:
  - the startup environment is interactive;
  - no active workflow is present;
  - no existing workflow data would be overwritten;
  - default package files are readable and valid enough to preview/import.
- Import the default package files through the existing workflow/settings package parser and persistence path, producing a normal active database workflow version.
- Store an import source such as `first_run_default_yaml` or similarly clear source metadata.
- Add a startup switch to suppress the prompt on first launch.
  - CLI flag candidate: `--no-default-yaml-prompt`.
  - Environment/config candidate: `SYMPHONY_NO_DEFAULT_YAML_PROMPT=1` or equivalent runtime setting.
  - The final implementation should choose a single documented operator-facing switch, with an env var if releases need non-CLI configuration.
- In suppressed or non-interactive mode, keep current setup-required behavior and log an actionable message that defaults were available but not imported.
- Add tests for empty database, missing defaults, invalid defaults, accepted import, declined import, and prompt suppression.
- Update README/user guide startup docs to explain first-run import and the opt-out switch.

## Out of Scope

- Reintroducing `workflow.yml` or `profiles.yml` as runtime sources after startup.
- Auto-importing defaults without operator consent.
- Overwriting an existing active workflow version.
- Adding a full setup wizard or Linear discovery flow.
- Changing Settings import review semantics.
- Importing arbitrary directories of YAML files.

## Acceptance Criteria

- With no database file and valid default YAML files present, first interactive startup asks whether to import defaults.
- Accepting the prompt creates and activates a database workflow version using validated import logic.
- Declining the prompt leaves the database without an active workflow and Symphony continues in setup-required mode.
- If the database already has an active workflow version, no prompt appears and no default file is read as runtime authority.
- If workflow versions exist but none is active, the implementation does not overwrite or auto-activate without a clear operator decision.
- If the opt-out switch is set, no prompt appears on first startup.
- Non-interactive startup never blocks waiting for input.
- Invalid or unreadable default YAML produces a clear setup-required message and does not create a partial workflow version.
- The default import source is visible in workflow version history or equivalent metadata.
- `workflow.yml` and `profiles.yml` remain examples/import packages after startup; subsequent runtime reads still come from the active database workflow.

## Test Cases

- CLI/runtime startup with empty SQLite database, interactive input `yes`, valid `workflow.yml` and `profiles.yml`:
  - prompt is displayed;
  - import succeeds;
  - active workflow version exists;
  - source metadata is `first_run_default_yaml` or the chosen equivalent.
- Same setup with input `no`:
  - no workflow version is created;
  - setup-required state is preserved.
- Empty database with `--no-default-yaml-prompt` or selected env/config switch:
  - no prompt is displayed;
  - setup-required state is preserved;
  - log explains how to import defaults manually.
- Existing active workflow:
  - no prompt;
  - no default import;
  - active workflow remains unchanged.
- Existing inactive workflow versions but no active version:
  - behavior is explicit and tested, either prompt with warning or setup-required with actionable instruction;
  - no silent overwrite.
- Missing `profiles.yml` or `workflow.yml`:
  - no crash;
  - setup-required state explains which default package file is missing.
- Invalid YAML:
  - parser error is shown/logged in bounded form;
  - no partial database records are activated.
- Release/packaged app fixture:
  - default package discovery works or is explicitly documented as development-only if packaged defaults are not shipped.

## Implementation Notes

- Keep import semantics in one place. Prefer extending `WorkflowSettingsPackage`, `WorkflowForm`, or the existing persistence import path instead of adding a startup-only parser.
- The first-run prompt should sit after database storage and migrations are available, but before the runtime commits to setup-required because no active workflow exists.
- Do not put this inside `Config.settings!/0` as an implicit side effect. Configuration reads should not unexpectedly mutate the database or block on stdin.
- The CLI currently accepts `--database-path`, `--logs-root`, and `--port`. If adding a CLI flag, update option parsing, usage text, and tests together.
- Interactive detection should be conservative. If stdin is not a TTY, or the app is started by a service manager/container, treat it as non-interactive and do not prompt.
- For web/server-only deployments, consider a visible setup-required banner that says defaults are available and links to Settings Import, but do not make the page itself mutate runtime configuration without confirmation.
- The default files may be split package files. The import should combine `workflow.yml` and `profiles.yml` the same way Settings import/export expects, preserving project/workflow/agent ownership boundaries.
- If the implementation needs bundled release defaults, add a small resolver that checks application priv/static or configured package path before falling back to the current working directory.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/cli_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_settings_package_test.exs`
- `mise exec -- mix test test/symphony_elixir/workflow_store_test.exs`
- `mise exec -- mix test test/symphony_elixir/auth_persistence_web_test.exs`
- `mise exec -- mix exec_plans.check`
- Manual smoke test:
  - remove or point to a fresh SQLite database;
  - start Symphony interactively;
  - accept default import;
  - verify Settings/Workflow history shows the imported active version;
  - restart and verify no prompt appears.

## Completion Deviations

Implemented a conservative first-run import assist with an opt-out CLI flag and environment switch. Interactive detection remains deliberately simple and can be forced in tests through application configuration.

## Dependencies

- Completed plan 017 for database-backed startup.
- Completed plan 018 for setup-required first workflow creation.
- Completed plan 080 for DB-only runtime workflow source.
- Completed plan 097 for setup-required prompt behavior.
- Completed plan 132 for staged Settings import semantics.
- Current package files `workflow.yml` and `profiles.yml`.

## Handoff Notes

This feature is a first-run convenience, not a runtime fallback. The implementation should be easy to reason about from logs and workflow version history: either defaults were explicitly imported into SQLite once, or Symphony stayed in setup-required mode and told the operator how to import them manually.
