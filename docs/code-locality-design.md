---
title: Code Locality Design
genre: design
domain: [backend, quality, testing]
status: current
language: en
updated: 2026-09-24
design_status: landed
---

# Code Locality Design

This L3 design owns repository-wide code locality: physical file boundaries, Elixir clause size,
control-flow nesting, implicit remote-call chains, policy literals, generated artifacts, and the
small set of review rules that cannot be decided from syntax alone. The current numeric and scan
contract is owned by [code-locality.md](code-locality.md).

## Intended structure

`SymphonyElixir.Locality` reads the single `config/locality.exs` manifest and checks the sorted Git
file set. `Mix.Tasks.Locality.Check` is the command boundary, and the existing `mix lint` path makes
it part of `scripts/check.sh`. Output is sorted by path and message, so a commit produces the same
text and exit status on repeated runs.

Large runtime modules retain their public module names and ownership. Their wrapper files compose
responsibility-named compile-time sections under the same module; in particular,
`SymphonyElixir.Orchestrator` remains the only GenServer and state owner. The split introduces no
process, configuration switch, compatibility entrypoint, fallback, message change, or second
implementation. Dashboard CSS is embedded from ordered layout and component files and produces the
same response body.

Large test modules use the same compile-time composition technique with scenario groups loaded by
`test/test_helper.exs`. Shared fixtures remain shared, while every physical test section stays below
the repository limit. Temporary long section macros and pre-existing long clauses are explicit debt
with exact measurements and dated cuts in the L4 contract; the checker rejects incomplete, stale,
expired, or more-than-30-days-out records.

## Decisions

- File length includes tracked handwritten implementation, tests, support, scripts, migrations,
  static assets, CI, and configuration. Markdown and declared data are outside the code scan.
- Elixir boundaries come from token-metadata AST, never regular-expression function parsing.
- Nesting follows Credo 1.7.16 `Credo.Check.Refactor.Nesting` with `max_nesting: 2`.
- A remote-call chain counts actual calls along the receiver path. Field access is not a call and an
  explicit pipeline is not an implicit receiver chain.
- Generated code/assets require one manifest entry and source/editing headers among the first five
  non-empty lines. The same manifest drives every locality exclusion.
- Human review covers conceptual locality, module-boundary intent, and literal classification. The
  five durable rules live in root `AGENTS.md`; machine thresholds remain in code and L4.

## Consequences

The quality gate blocks new oversized files, unregistered long clauses, excessive nesting, implicit
three-call chains, stale exclusions, and malformed generated headers. A temporary clause record is
visible debt rather than a permanent grandfather list. Removing a record requires reducing the
measured clause to the limit; changing its line count or identifier invalidates it immediately.

This owner changes repository organization and quality enforcement only. Product behavior, public
interfaces, runtime configuration authority, persistence, Linear behavior, and deployment remain
owned by their existing designs and contracts.
