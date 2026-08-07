# Task 001: Simple Username Password Authentication

## Status

**Status**: Completed
**Priority**: HIGH
**Dependencies**: None
**Created**: 2026-05-01

## Goal

Add simple username/password authentication for the Symphony Web UI and JSON API so the dashboard is not exposed as an unauthenticated control surface.

## Background

Symphony is moving from a local observability page toward a long-running Web service with configuration editing and operational controls. The current dashboard/API can expose runtime state and will eventually expose actions such as refresh, retry, stop, configuration edits, and secret metadata management.

Before those controls grow, the service needs a minimal authentication boundary.

This plan intentionally starts with a simple local-user model instead of OAuth or SSO. The goal is a pragmatic first security layer suitable for local and trusted deployments.

## Scope

- Add session-based login for Phoenix browser routes.
- Protect the LiveView dashboard route.
- Protect JSON API routes.
- Add a login page and logout action.
- Store the admin username and password hash in configuration or SQLite, depending on whether Task 002 has already landed.
- Use password hashing, not plaintext password comparison.
- Add a default disabled state or explicit setup requirement so the service does not silently ship with a known password.
- Add tests for authenticated and unauthenticated access.

## Out of Scope

- OAuth, SAML, OIDC, or SSO.
- Multi-user roles and permissions.
- Password reset email flows.
- User self-registration.
- Fine-grained per-project authorization.

## Acceptance Criteria

- [ ] Unauthenticated browser requests to `/` redirect to the login page.
- [ ] Unauthenticated requests to `/api/v1/state`, `/api/v1/refresh`, and `/api/v1/:issue_identifier` return an authentication error.
- [ ] Valid username/password creates a signed session.
- [ ] Invalid credentials do not create a session and show a safe error.
- [ ] Logout clears the session.
- [ ] Passwords are verified using a password hashing library.
- [ ] No default shared password is accepted unless explicitly configured by the operator.
- [ ] Existing dashboard behavior works after login.
- [ ] Existing API behavior works when authenticated.

## Test Cases

- Login page renders for unauthenticated users.
- Unauthenticated `GET /` redirects to login.
- Unauthenticated API requests return `401` or another explicit authentication error.
- Valid credentials create a session and allow dashboard access.
- Invalid username/password does not create a session.
- Logout clears the session and blocks subsequent dashboard access.
- Password verification uses the configured hash and does not accept plaintext fallback values.
- Authenticated API requests preserve existing JSON response behavior.
- Missing authentication configuration fails closed or produces an explicit setup error.

## Implementation Notes

- Prefer Phoenix sessions for browser authentication.
- Add a small authentication plug for API routes.
- Keep the first version intentionally simple: one configured admin user is enough.
- If Task 002 lands first, store the user/password hash in SQLite. If not, use environment/config first and migrate to SQLite later.
- Authentication should protect the dashboard before configuration editing is introduced.

## Verification

- `mise exec -- mix test test/symphony_elixir/cli_test.exs`
- Add focused tests for login, logout, protected LiveView routes, and protected API routes.
- Run the full suite with `mise exec -- mix test`.
- Manually start with `--port`, confirm unauthenticated dashboard access redirects to login, then login and load the dashboard.

## Completion Deviations

- Implemented optional authentication, disabled by default for backwards compatibility.
- The first version supports one configured admin identity through env/config or an existing SQLite user record.
- Password reset, multi-user management, and role authorization remain out of scope as planned.

## Handoff Notes

- Record where credentials are stored.
- Record whether this version uses config/env or SQLite.
- Record any planned migration path if SQLite is not available yet.
