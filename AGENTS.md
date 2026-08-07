# Symphony

This directory contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from the active SQLite workflow version and should be accessed through
  `SymphonyElixir.Config`. `workflow.yml` and `profiles.yml` are split package import/export
  artifacts and examples, not the live runtime source.
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

## Code Value Principles (Linus & Carmack)

Evaluate every change — and every existing line — against the value it provides, with the
discipline of Linus Torvalds and John Carmack:

- **Linus: remove complexity, keep good taste.** The kernel philosophy: a change that makes the
  system simpler is better than one that makes it more elaborate. Refuse architecture-astronaut
  abstractions — layers with one implementation, config nobody reads, indirection with no
  consumer. Code must earn its place.
- **Linus: talk is cheap, show me the code.** Prefer concrete, working, minimal changes over
  design essays. When in doubt, delete the branch nobody exercises and see whether anything
  breaks — that is the test of value.
- **Carmack: minimize the number of things that can go wrong.** Every feature, flag, abstraction,
  and catch-all rescue is a thing that can go wrong. No speculative config keys, no catch-all
  rescues that hide real failures, no dual representation of one fact (`listening?` + mode, two
  lifecycle implementations, string-discriminated state maps).
- **Carmack: hard to make simple is still worth it.** Code that is hard to understand is hard to
  make correct. If a reviewer needs a tour through a 2000-line LiveView or a five-way conditional,
  that is debt — simplify, don't document around it.
- **Explicit errors over silent tolerance.** Failures must be visible (structured logs) and
  typed. Never disguise a database fault as "setup required", never swallow a crash to keep a
  pipeline alive with no record, never fail open on a rate-limit gate.

## Documentation Layers

| Layer | Purpose |
| --- | --- |
| L0 | Governance: contributor rules, decisions, and exec-plan history. |
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

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `README.md` for project concepts, goals, and implementation/run instructions.
- `workflow.yml` and `profiles.yml` when the import/export workflow package
  contract changes. The SQLite active workflow version is the runtime
  authority; local split package files are examples/import artifacts, not the
  live runtime source.
- `docs/documentation_alignment.md` when a change affects runtime source,
  Settings ownership, worker modes, observability/analytics, Linear
  integration, deployment ownership, or other long-lived documentation claims.
