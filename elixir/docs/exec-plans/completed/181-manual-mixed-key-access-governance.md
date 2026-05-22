# 181 Manual Mixed Key Access Governance

## Goal

Stop new ad hoc atom/string key fallback code from spreading across presenters, protocol parsers, and persistence helpers.

## Status

Completed.

## Background

`SymphonyElixir.Payload.get_any/3` and `get_path/3` exist, but manual mixed-key access still appears in many places:

- `Map.get(map, :key) || Map.get(map, "key")`
- local `map_get/3` helpers;
- repeated `Payload.get_path(...) || Payload.get_path(...)` ladders;
- duplicated debug-value helpers in web presenters.

Some of this is acceptable at external payload boundaries, but uncontrolled duplication makes key-shape behavior inconsistent and makes payload parsing hard to audit.

## Scope

- Audit manual mixed-key fallback sites under `lib/`.
- Replace local fallback helpers with `Payload.get_any/3` or purpose-specific accessors where the data is external payload.
- Keep direct `Map.get/2` for structs/internal maps where the key shape is known.
- Add a static governance test that flags new obvious mixed-key fallback patterns unless explicitly exempted.

## Out of Scope

- Mechanical replacement that makes known-key code less readable.
- Changing public payload shapes.
- Removing support for existing atom/string external payloads.
- Rewriting all message humanizer path ladders in one change.

## Acceptance Criteria

- Mixed-key fallback is centralized or justified.
- New duplicated `Map.get(... :key) || Map.get(... "key")` patterns fail a focused test.
- External payload parsing remains tolerant where the runtime receives both atom and string keys.
- Internal data paths do not pretend to support both shapes unnecessarily.

## Verification

- `rg -n "Map\\.get\\([^\\n]+\\|\\||map_get\\(|Payload\\.get_path\\([^\\n]+\\) \\|\\|" lib`
- Focused governance test for mixed-key fallback patterns
- `mix test test/symphony_elixir/state_name_payload_test.exs`
- `mix exec_plans.check`

