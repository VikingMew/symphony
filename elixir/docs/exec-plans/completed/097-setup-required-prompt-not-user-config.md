# 097 Setup Required Prompt Is Not User Configuration

## Goal

Prevent the setup-required placeholder prompt from appearing as an editable Base Prompt or being saved as real workflow configuration. When no active workflow exists, Settings should show that configuration is missing without injecting `"Create a workflow from the Web UI to start running agents."` into the Agents form.

## Status

Completed.

## Background

The empty-database path constructs a setup-required workflow so Settings pages can render before the first real workflow version exists. That workflow currently carries:

```text
Create a workflow from the Web UI to start running agents.
```

This string is useful as a system status hint, but it is not a base prompt. Because it is stored in the same `prompt_body` shape used by real workflow versions, `/settings/agents` renders it in the Base Prompt textarea. Operators can reasonably mistake it for the correct seed prompt and save it into the database.

The correct Symphony seed prompt lives in `profiles.yml` as `base_prompt`. Runtime should never treat the setup-required hint as user-authored prompt configuration.

## Scope

- Separate setup-required status text from workflow `prompt_body`.
- Ensure `Workflow.setup_required_workflow/1` or its consumers expose an empty prompt body for editable configuration surfaces.
- Ensure `/settings/agents` shows either an empty Base Prompt or a clear setup-required empty-state, not the placeholder hint inside the textarea.
- Ensure save paths do not persist the setup-required placeholder prompt unless the operator explicitly types that exact text into a real draft.
- Preserve a human-readable setup-required message in page status/checklist areas where it is a status hint.
- Update tests that currently assert `PromptBuilder.build_prompt/1` returns the setup-required placeholder as an executable prompt.
- Add regression tests covering `/settings/agents` empty-database rendering and save behavior.
- Update docs so `Create a workflow from the Web UI...` is described as a setup hint, not a valid base prompt.

## Out of Scope

- Do not change the real default fallback prompt in `SymphonyElixir.Config` unless it is also leaking into setup-required forms.
- Do not auto-import `profiles.yml` on startup.
- Do not add a CLI import command.
- Do not redesign the full first-run setup flow beyond fixing this prompt leak.
- Do not make local package files a runtime source again.

## Acceptance Criteria

- Empty database `/settings/agents` does not show `Create a workflow from the Web UI to start running agents.` inside the Base Prompt textarea.
- The setup-required status remains visible somewhere appropriate, such as the Settings checklist or runtime source summary.
- Saving from setup-required state cannot accidentally persist the placeholder prompt as the workflow base prompt.
- A real active workflow with an intentionally configured base prompt still renders and saves normally.
- PromptBuilder behavior is explicit for setup-required state: either it refuses to build an agent prompt with setup-required configuration, or it returns a non-user-configured setup message through a clearly named branch that cannot be mistaken for a saved prompt.
- Tests document the distinction between setup status message and editable prompt body.

## Test Cases

- Reset fake persistence to no active workflow, render `/settings/agents`, and assert:
  - the Base Prompt textarea is empty or absent;
  - setup-required guidance is visible outside the textarea;
  - the placeholder text is not present in `workflow[prompt_body]`.
- Save an Agents draft from setup-required state without editing Base Prompt; assert the saved workflow prompt is empty or seeded only by an explicit import path, never by the setup placeholder.
- Load a normal workflow version with `prompt_body: "Real base prompt"`; assert `/settings/agents` renders that exact prompt and save preserves it.
- Call `PromptBuilder.build_prompt/1` with setup-required workflow state and assert the behavior matches the new contract.
- Run focused web fake persistence and core prompt tests.

## Implementation Notes

- Prefer removing `@setup_prompt` from the loaded workflow data model and replacing it with a field such as `setup_message` only if consumers need a display string.
- If keeping a setup message in `Workflow.setup_required_workflow/1`, keep it outside `prompt` and `prompt_template`.
- Audit all callers of `workflow.prompt`, `workflow.prompt_template`, and form initialization so setup-required data cannot flow into `WorkflowForm`.
- The Settings UI should source setup guidance from `@workflow_setup_required` or configuration checklist state, not from prompt fields.
- The checked-in seed prompt remains `elixir/profiles.yml` `base_prompt`; this plan only prevents the wrong fallback from masquerading as it.

## Verification

- Passed `mise exec -- mix format`.
- Passed `mise exec -- mix test test/symphony_elixir/web_fake_persistence_test.exs test/symphony_elixir/core_test.exs`.
- Passed `mise exec -- mix test` with 358 tests, 0 failures, 2 skipped.
- Passed `mise exec -- mix lint`.
- Passed `mise exec -- mix build`.
- Passed `mise exec -- mix format --check-formatted`.
- Passed `git diff --check`.
- Browser-verified `/settings/agents` on a setup-required database: Base Prompt is empty, setup placeholder is not in the textarea, and Settings import controls are visible.

## Completion Deviations

- `Workflow.setup_required_workflow/1` now keeps the setup hint as `setup_message` and leaves `prompt` / `prompt_template` empty. `PromptBuilder` still returns the setup message through an explicit setup-required branch so existing non-runtime diagnostic behavior remains stable, but that message no longer flows through editable prompt fields.

## Dependencies

- Completed plan 076 for `profiles.yml` owning `base_prompt`.
- Completed plan 080 for DB-only runtime workflow source.
- Completed plan 093 for save-only-when-dirty behavior.

## Handoff Notes

The important distinction is product semantics: setup-required is a system state, not a workflow version. Do not solve this by replacing the placeholder with the large seed prompt. The seed prompt should arrive through an explicit import or seed action, not an implicit startup fallback.
