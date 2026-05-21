# 135 Profile Prompt Guidance

## Goal

Make the Agent Settings page show prompt guidance for every execution profile/phase, not only the shared Base Prompt summary.

Operators should be able to understand, at a glance, which prompt each profile contributes, how it combines with the Base Prompt, and whether each phase has enough stage-specific instructions.

## Status

Completed.

## Background

The Agent Settings page currently shows a top-level `Prompt` metric for the shared Base Prompt, such as `1373 chars`, and the page has a `Base Prompt` section with explanatory copy. Below that, each profile has a `Prompt` subsection with `Prompt mode` and `Profile prompt template`, but the page does not give equivalent per-profile prompt guidance or metrics.

This creates ambiguity:

- The top summary makes it look like only the Base Prompt has a prompt length.
- Users cannot quickly see whether `refinement`, `implementation`, `merge`, or other profiles have phase-specific prompt text.
- Users cannot tell whether a profile is extending, replacing, or disabling the Base Prompt without opening and interpreting each field.
- Users cannot see the estimated final prompt contribution per phase.
- Missing or very short stage-specific prompts are not called out as a configuration risk.

Completed plan 044 made execution profiles first-class stage-specific configuration. Completed plan 076 moved the shared Base Prompt into profile configuration. The UI should now make every profile's prompt behavior explicit.

## Scope

- Add per-profile prompt metrics to the Agent Settings page.
- For every profile/phase card, show:
  - prompt mode (`extend`, `replace`, `disabled`);
  - profile template character count;
  - effective prompt character count, when computable;
  - whether the Base Prompt is inherited, replaced, or ignored;
  - a concise warning when a Codex agent profile has no useful prompt.
- Add contextual help text for every profile prompt section, not only the Base Prompt section.
- Add a preview or expandable summary of the effective prompt composition for each profile:
  - Base Prompt + profile template for `extend`;
  - profile template only for `replace`;
  - no prompt for `disabled`;
  - backend/manual profiles should explain whether prompt fields are ignored.
- Update the top summary so it distinguishes:
  - shared Base Prompt length;
  - number of profiles with prompt templates;
  - number of profiles with disabled/empty prompts.
- Keep the UI compact and scannable; avoid adding a large always-expanded prompt preview for every profile.
- Add tests for rendering prompt metrics and warnings.

## Out of Scope

- Do not change runtime prompt rendering semantics.
- Do not add a new prompt template language.
- Do not change profile schema fields unless needed for display-only normalization.
- Do not require non-Codex profiles to have prompt text.
- Do not auto-generate missing prompts.
- Do not rewrite the whole Agent Settings layout.

## Acceptance Criteria

- Every profile card shows prompt-specific guidance or metrics.
- Every profile card shows the profile prompt template character count.
- Codex agent profiles show whether their effective prompt extends, replaces, or disables the Base Prompt.
- Codex agent profiles with empty or disabled effective prompts show a warning.
- Non-Codex profiles explain when prompt fields are not used by that executor.
- The top Agent Settings summary no longer implies that only the Base Prompt has prompt length.
- The UI provides an effective prompt preview or composition summary per profile without overwhelming the page.
- Existing save/import behavior for profiles remains unchanged.

## Test Cases

- Profile with `prompt_mode: extend` and non-empty template:
  - UI shows Base Prompt is inherited;
  - UI shows profile template char count;
  - UI shows effective prompt char count.
- Profile with `prompt_mode: replace`:
  - UI says Base Prompt is replaced;
  - effective prompt count reflects only profile template.
- Profile with `prompt_mode: disabled`:
  - UI says prompt is disabled;
  - Codex agent profile shows a warning if this would leave no prompt.
- Codex agent profile with empty template:
  - UI warns when prompt composition is ineffective or too thin.
- Backend/manual profile:
  - UI explains prompt is ignored or not used for Codex execution.
- Top summary:
  - displays Base Prompt length separately from profile prompt metrics.
- Existing Agent Settings save tests continue to pass.

## Implementation Notes

The current Agent Settings UI is rendered in `SymphonyElixirWeb.AdminLive` under the `:settings_agents` branch. The existing profile cards already iterate over `profile_entries(@workflow_form)` and render:

- profile name;
- executor type;
- prompt mode;
- profile prompt template;
- allowed updates;
- target states.

Prefer extracting small helper functions for prompt metrics rather than embedding calculations in the template:

```elixir
profile_prompt_summary(base_prompt, profile)
```

Potential summary fields:

```elixir
%{
  mode: "extend",
  template_chars: 420,
  effective_chars: 1793,
  uses_base_prompt?: true,
  prompt_used?: true,
  warning: nil | String.t()
}
```

Use the existing prompt rendering semantics as the source of truth where possible. If a prompt builder helper already computes effective prompt content, reuse it; otherwise mirror only enough logic for display and test it against runtime behavior.

Keep previews collapsed by default with `<details>` or a compact "Preview effective prompt" control. The default card should remain scannable.

Use "profile" in code/docs to match the existing schema. If UI copy says "phase", clarify that each routed phase/state uses a profile.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/profile_prompt_summary_test.exs test/symphony_elixir/web_fake_persistence_test.exs`
- Focused helper tests cover `extend`, `replace`, `disabled`, Codex, backend, and manual profile prompt summaries.
- Focused Agent Settings LiveView tests cover top prompt metrics, per-profile template/effective character counts, Base Prompt usage copy, and effective prompt previews.
- Existing Settings/profile import/save tests are included in the focused web persistence test command.
- `mise exec -- mix test --cover` passed with 432 tests, 0 failures, 2 skipped, 85.75% total coverage.
- `mise exec -- mix lint`
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

The UI follows current runtime semantics for `prompt_mode: disabled`: it disables the profile-specific prompt contribution while leaving the shared Base Prompt in place. The plan's shorthand "no prompt for disabled" was treated as "no profile prompt contribution" rather than a runtime behavior change.

## Dependencies

- Completed plan 044 for stage-specific execution profiles.
- Completed plan 076 for profile-owned Base Prompt.
- Completed plan 098 for split profile package import.
- Existing Agent Settings profile editor.

## Handoff Notes

This is a visibility and correctness-aid task. Runtime prompt behavior should not change; the UI should make the existing behavior understandable for every profile/phase.
