# Database Inline Profile Normalization

## Status

**Status**: Completed

## Goal

Make profile storage database-first and self-contained. A saved workflow version must contain every state routing rule and every profile definition needed at runtime. `WORKFLOW.md` is a workflow package import/export artifact: it contains one `workflow` object plus top-level `profiles`. Local YAML files may be used later as import/export convenience, but runtime must not depend on profile directories or files next to `WORKFLOW.md`.

## Background

The earlier profile-file direction reduced indentation, but it conflicts with Symphony's main operating model: workflow versions are stored in the database and activated from the Web UI. If an active database workflow points to local files, runtime behavior depends on files that may not exist on dashboard or worker nodes and cannot be reviewed or versioned as one contract.

The corrected model is:

- `workflow.states` maps a Linear state to a profile id.
- top-level `profiles` stores all profile definitions inline.
- `WORKFLOW.md` imports/exports both of those top-level sections together as one workflow package.
- each profile definition includes a `name` field for human-readable display, prompt context, logs, and diagnostics.
- `profiles.<id>.active_states` is not part of the new contract. State routing must be explicit under `workflow.states`.

## Scope

- Define the canonical inline workflow shape:

```yaml
workflow:
  states:
    Refining:
      profile: refinement
    Ready:
      profile: implementation
    In Progress:
      profile: implementation
    Ready to Merge:
      profile: merge
    Merging:
      profile: merge

profiles:
  refinement:
    name: "Refinement"
    executor:
      type: codex_agent
    prompt:
      mode: extend
      template: |
        Turn the current idea and comments into a precise task.
    allowed_updates:
      description: true
      comment: true
      result: false
      target_states: ["Needs Refinement Review"]
```

- Validate state routing references only existing profiles.
- Validate every profile has a non-empty `name`.
- Preserve profile id and profile name in runtime helper APIs.
- Update docs and templates to use `workflow.states` instead of `active_states` inside profiles.
- Keep `WORKFLOW.md` and database export/import as a single complete artifact.

## Out of Scope

- Reading profile definitions from separate files at runtime.
- Watching local profile directories.
- Supporting remote profile URLs or arbitrary includes.
- Building a full multi-document workflow editor.

## Acceptance Criteria

- [ ] A database workflow version with `workflow.states` and top-level `profiles` parses successfully.
- [ ] State lookup resolves `Refining -> refinement` and exposes profile name `Refinement`.
- [ ] Unknown profile references in `workflow.states` are rejected.
- [ ] `profiles.refinement.active_states: ["Refining"]` is rejected because routing belongs under `workflow.states`.
- [ ] `workflow.profiles` is rejected because profile definitions belong at top-level `profiles`.
- [ ] New generated workflow templates do not emit profile directory or profile file references.
- [ ] Exported workflow markdown is self-contained.

## Test Cases

- `Config.Schema.parse/1` accepts the canonical `workflow.states` shape.
- `Config.Schema.workflow_profile_for_state/2` resolves states from `workflow.states`.
- `Config.Schema.workflow_profile/2` returns the top-level profile map including `name`.
- `Config.Schema.parse/1` rejects `states.Ready.profile: missing`.
- `Config.Schema.parse/1` rejects `profiles.refinement.active_states`.
- `Config.Schema.parse/1` rejects `workflow.profiles`.
- `Workflow.to_markdown/2` export contains `workflow.states` and top-level `profiles`, not file references.

## Implementation Notes

- Treat the profile map key as the stable id and `profile.name` as display metadata.
- Require `name` so UI and prompt diagnostics do not infer display semantics from ids.
- `workflow.states.<state>` can initially be a map with `profile`, and may later grow fields such as `activity`, `review_gate`, or `priority`.
- Keep the validator close to `Config.Schema`; this is schema normalization, not filesystem resolution.
- Any future file import should resolve files before save and persist the resolved, inline workflow version.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix lint`
- [ ] `mise exec -- mix test test/symphony_elixir/core_test.exs`
- [ ] `mise exec -- mix test test/symphony_elixir/workflow_store_fake_persistence_test.exs`
- [ ] `mise exec -- mix test`
- [ ] `git diff --check`

## Completion Deviations

- Profile definitions are top-level `profiles`; `workflow` only owns state routing and workflow rules.
- Missing top-level `profiles` still receives built-in defaults so an omitted workflow section can bootstrap cleanly, but explicit custom profile config must use the new top-level shape.

## Dependencies

- Task 044 defines stage-specific profile semantics.
- Task 040 validates edited workflow versions before save or activation.

## Handoff Notes

This plan replaces the old external-profile-file approach. The runtime contract is one activated workflow version from the database, containing complete state routing and profile definitions.
