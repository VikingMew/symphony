# 153 - Linear Client Response Normalization Boundary

Status: Completed

## Problem

`SymphonyElixir.Linear.Client` mixes GraphQL transport, query execution, pagination, issue normalization, assignee routing filters, error sanitization, and response decoding.

Issue normalization and pagination are pure logic but currently live beside HTTP request construction and token/header handling. This makes Linear API behavior harder to test without transport setup and keeps multiple reasons to edit the same client file.

## Goal

Extract response normalization and pagination into focused modules, for example:

- `SymphonyElixir.Linear.IssueNormalizer`
- `SymphonyElixir.Linear.Pagination`

The client should own GraphQL transport and call these modules for decoding.

## Plan

1. Inventory helpers for page cursor handling, issue ordering, issue normalization, labels/blockers extraction, datetime/priority parsing, and assignee filtering.
2. Move pure normalization and pagination helpers into focused modules.
3. Keep GraphQL HTTP transport, headers, and request options in `Linear.Client`.
4. Replace `_for_test` wrappers with direct tests against extracted modules.
5. Add tests for paginated response merging, missing cursors, assignee matching, blocker extraction, label extraction, requested-id ordering, and malformed issue payloads.
6. Preserve the public `Linear.Client` API.

## Verification

- `mise exec -- mix format`
- `mise exec -- mix test test/symphony_elixir/linear_issue_normalizer_test.exs test/symphony_elixir/linear_pagination_test.exs test/symphony_elixir/workspace_and_config_test.exs` - 68 tests, 0 failures
- `rg -n "normalize_issue_for_test|next_page_cursor_for_test|merge_issue_pages_for_test|normalize_issue|extract_labels|extract_blockers|assigned_to_worker|sort_issues_by_requested_ids" lib test`
- `mise exec -- mix exec_plans.check`

## Completion Deviations

- There is no dedicated `test/symphony_elixir/linear_client_test.exs` in the current tree, so the regression command used the existing Linear client coverage in `workspace_and_config_test.exs` plus focused pure-module tests.
