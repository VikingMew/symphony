# Symphony

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `scripts/setup.sh`.
- Make is reserved for build/image targets. `scripts/e2e.sh` is a credentialed manual live E2E suite,
  not a CI gate.

### Build

Run `mix build` after `mix setup`.

### Run

With `DATABASE_URL` set, run `mix symphony.migrate`, then `mix phx.server`.

### Test

Run `scripts/check.sh && scripts/unit.sh && scripts/dialyzer.sh`.

### Navigation

Use the [module map](docs/design.md) and `rg -n "defmodule|def |@type|@opaque" lib test`
to locate code by concept. For naming details and current exceptions, see the
[N-conformance record](docs/agent-facing-code-n-conformance.md).


## Codebase-Specific Conventions

- Runtime config is loaded from the project's current PostgreSQL workflow snapshot and should be accessed through
  `SymphonyElixir.Config`. The package under `docs/examples/` is example and import material, not a
  configuration source; change configuration through Settings (or Settings / Import), never with a
  manual SQL `UPDATE`.
- Keep the implementation aligned with [`docs/spec.md`](docs/spec.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.
- Keep each file focused enough to understand one concept without navigating elsewhere; record the deterministic locality sample in `docs/code-locality.md`.
- Do not cross module boundaries through three or more implicit remote calls; name intermediate values or use an explicit pipeline.
- Give repeated or policy-bearing literals a named constant or existing `SymphonyElixir.Config` setting, and classify intentional literals in the locality audit.
- Track generated code/assets only with a canonical manifest entry plus `Generated from:` and `DO NOT EDIT` in the first five non-empty lines.
- Keep the locality split index beside every temporary overlong clause and update its owner, cut, measured lines, and due date in the canonical manifest.

## Code Value Rules

- Remove complexity that does not serve a current consumer. Delete unused branches, speculative
  configuration, single-implementation layers, and needless indirection.
- Prefer concrete, working, minimal changes. Prove uncertain value with executable code and tests.
- Minimize independent states, flags, abstractions, and failure paths. Represent each fact once.
- Simplify code that needs a tour to understand. Improve its structure instead of documenting
  around avoidable complexity.
- Trust declared contracts and types. Do not add fallback branches for excluded states or
  catch-all rescues that hide failures.
- Surface failures as explicit typed results and structured logs. Do not disguise database faults,
  swallow crashes, or fail open at a gate.

## Pre-release Stance (no external consumers)

Remove this section at the first tagged release. With no external consumers, prefer the correct
foundation over compatibility shims: rename or repackage freely and update every reference
together. Ecto migrations are monotonic; old on-disk formats are rejected — no compatibility
shim for old DB schema versions. This deletion authority is time-boxed: it expires at first
release, after which compatibility matters again.

## Documentation Layers

| Layer | Purpose |
| --- | --- |
| L0 | Governance: contributor rules and decision history. |
| L1 | System architecture: topology, boundaries, invariants, and long-term direction. |
| L2 | Backend design: package layout, implementation conventions, and the feature-design index. |
| L3 | Feature designs: one concern and one owned contract per design document. |
| L4 | Normative contracts: specifications and reference tables without roadmap narrative. |
| L5 | Operational guides: procedures validated by whether an operator can run them. |

- Each contract has exactly one owning document; other documents link, not restate.
- Every new document must be placed in exactly one layer and registered in `docs/README.md`.
- L2, L4, and L5 describe current behavior; future intent belongs in an L3 design with an explicit status.
- L1 and L4 use English; L3 and L5 may use zh-CN when declared in frontmatter.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

Prefer positive assertions of documented behavior and exact expected values.
Use `refute` only for timing bounds or security/protocol redlines grounded in an
owning contract, and cite that contract in the adjacent test name or comment.

Code conformance and test conformance are independent; passing either one does not prove the other.
Tightened gates use a shrinking exact baseline and become one hard path only when that baseline is empty.
Every unmet or partially met conformance item needs a remediation plan; not-applicable items need a reason.

Symphony agent refinement and implementation must not perform container-engine or image-level
validation. Review Compose deployment changes against the owning contract in
[`docs/compose.md`](docs/compose.md); use static source/config tests only.

## Quality Gates

Keep this resident rule file concise and move detailed guidance into on-demand documentation.
Run `scripts/quality.sh` before handoff; see [repository verification](docs/repository-verification-design.md).

- Keep ordinary tests selectable by file/line and tags without running the full gate.
- Control time/random inputs that affect outcomes; keep HTTP fixtures offline or on literal loopback.
- Assert exact actual/expected values and retain localized failure evidence.
- Keep credentialed or manual validation opt-in and outside the default suite.

## Required Rules

- Choose names that state intent and role; do not add encoded prefixes, type abbreviations, or
  Hungarian-style names.
- Use the glossary term for each concept; do not introduce a listed declaration synonym.
- Organize directories by domain; do not add date-, person-, phase-, stage-, or batch-named mainline directories.
- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Keep public interfaces narrow: make required inputs explicit, keep defaults safe, and omit parameters without current consumers.
- Keep cross-call mutable state in an owned OTP or startup boundary; pass or inject other shared state explicitly.
- When changing a dependency or tool/action pin, include its lock or pin update and record the upgrade reason in the same change.
- For uncertain external behavior, add an offline boundary contract test that names the assumed response or failure semantics.
- Do not add invented version numbers to new or modified documentation or generated content, including
  unsupported title/body versions, badges, or changelog-style labels for one-off plans.
- Use version numbers only when they carry real release, compatibility, protocol/API, dependency, or
  external meaning, such as repository releases, image tags, pinned tools/runtimes, and lockfiles.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.
- Keep comments only for non-obvious intent, surprising decision rationale, external protocol
  assumptions, or source attribution.
- Do not restate code in comments or use comments to compensate for unclear names or structure.
- Preserve comments that remain valid during refactors. Update or remove stale comments with the
  code, and record the reason for each changed or removed comment in the owning conformance record.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR bodies must follow the canonical [PR body contract](docs/pull-request-body.md).
  `.github/pull_request_template.md` is only the synchronized GitHub entry copy.
- Implementation agents call the restricted `create_pull_request` tool only after validation,
  commit, and push, then include its returned URL and completion proof in the final Linear
  completion references.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- For behavior or architecture changes, use the Feature Design Index in `docs/design.md` and the
  canonical rows in `docs/documentation-alignment.md` to identify the owning L3 design. Update that
  design and its alignment row in the same change.
- If no owner exists, state that explicitly in the task and PR, then register a new L3 owner or
  merge the concern into an existing owner in the same change before merging. A missing owner is
  not an exemption from design synchronization.

- `README.md` for project concepts, goals, and implementation/run instructions.
- `docs/examples/workflow.yml` and `docs/examples/profiles.yml` when the example package format
  changes. The PostgreSQL current workflow is the runtime authority; local split package files are
  examples/import artifacts, not the live runtime source.
- `docs/documentation-alignment.md` when a change affects runtime source,
  Settings ownership, worker modes, observability/analytics, Linear
  integration, deployment ownership, or other long-lived documentation claims.
