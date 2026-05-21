# 155 - Dashboard Live Presentation Boundary

Status: Completed

## Problem

`SymphonyElixirWeb.DashboardLive` is smaller than the largest runtime modules, but it still embeds a large render function plus many presentation helpers for runtime duration, badges, listening state, session history keys, rate-limit debug fields, and pretty payload formatting.

The LiveView should own socket events and assigns. It should not also own every display formatting rule for dashboard rows and debug payloads.

## Goal

Extract dashboard presentation helpers into a focused presenter boundary, likely extending `SymphonyElixirWeb.Presenter` or adding `SymphonyElixirWeb.DashboardPresenter`.

The LiveView should delegate formatting and derived row data, keeping only event handling and render composition.

## Plan

1. Inventory all `DashboardLive` private helpers that format values or derive display classes.
2. Move pure helpers for runtime formatting, badges, session-history key/summary, rate-limit debug display, and pretty payload truncation into a presenter module.
3. Keep socket event handlers and refresh scheduling in the LiveView.
4. Add focused presenter tests for badge classes, runtime formatting, session history keys, rate-limit debug fallback fields, and truncation.
5. Keep rendered dashboard tests to prove the page still displays the same operator-facing content.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir_web/dashboard_presenter_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/dashboard_signal_test.exs` - 26 tests, 0 failures
- `rg -n "format_runtime|rate_limit_badge|state_badge|history_badge|session_history_key|rate_limit_debug|pretty_value|truncate_string" lib test`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

- There is no dedicated `test/symphony_elixir_web/live/dashboard_live_test.exs` in the current tree, so rendered dashboard regression coverage used the existing dashboard cases in `extensions_test.exs` and `dashboard_signal_test.exs`.
- While running the rendered dashboard tests, an existing Linear unknown detail assertion was updated to match the current `LinearStatusSignal` copy: "Open Linear diagnostics to run connectivity and state checks."
