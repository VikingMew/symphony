# Task 031: Runtime Proxy Environment Support

## Status

**Status**: Planned
**Priority**: HIGH
**Dependencies**: Tasks 022, 029, 030
**Created**: 2026-05-06
**Completed**: N/A

## Goal

Support proxy configuration at startup through environment variables for both:

- the Symphony main process, including Linear API calls and any HTTP clients running inside the Elixir application;
- Codex child processes launched by Symphony, including `codex app-server` sessions in local all-in-one mode and remote worker mode when the environment is passed through.

The implementation should work in local shell runs, Docker all-in-one runs, dashboard images, and Codex worker images without requiring users to edit `WORKFLOW.md` for every environment.

## Background

Symphony deployments may run in regions or corporate networks where direct access to public services is unavailable. Docker builds already expose mirror/proxy build args, but runtime traffic still needs a clear proxy contract.

There are two runtime paths:

- Symphony itself makes outbound HTTP calls, especially to Linear GraphQL.
- Symphony launches `codex app-server` through `bash -lc <codex.command>`. Codex needs proxy variables in its process environment for OpenAI/Codex network calls.

The current default workflow command includes `--config shell_environment_policy.inherit=all`, but the runtime behavior should not depend on a specific workflow file preserving that string forever. The proxy story needs to be explicit, documented, and tested.

## Scope

- Define supported runtime environment variables:
  - `HTTP_PROXY`
  - `HTTPS_PROXY`
  - `ALL_PROXY`
  - `NO_PROXY`
  - lowercase aliases: `http_proxy`, `https_proxy`, `all_proxy`, `no_proxy`
- Ensure Symphony's Elixir HTTP clients honor these variables for outbound requests.
- Ensure locally launched Codex app-server processes receive the proxy variables.
- Ensure Docker image examples document passing proxy variables with `-e`.
- Ensure worker image examples document passing proxy variables into the worker container.
- Preserve normal behavior when proxy variables are absent.
- Avoid logging full proxy URLs if they contain credentials.

## Out of Scope

- Implementing a proxy server.
- Managing organization-specific CA certificates.
- Adding PAC file support.
- Adding SOCKS support beyond what underlying HTTP clients and Codex already support through `ALL_PROXY`.
- Adding UI forms for proxy configuration.
- Persisting proxy values in SQLite workflow versions.
- Requiring `WORKFLOW.md` edits for proxy-only deployment differences.
- Guaranteeing proxy behavior for third-party tools executed by arbitrary workspace hooks.

## Acceptance Criteria

- [ ] Symphony can start with proxy env vars set and still load config, start Repo, start Phoenix, and poll Linear.
- [ ] Linear diagnostics and Linear client requests use the configured proxy when proxy env vars are present.
- [ ] Proxy env vars are inherited by local Codex app-server child processes.
- [ ] Proxy env vars can be passed to Docker `all-in-one`, `dashboard-*`, and `worker` containers with `-e`.
- [ ] Sensitive proxy credentials are not logged in raw form.
- [ ] Absence of proxy env vars does not change current behavior.
- [ ] README documents runtime proxy env vars separately from Docker build-time mirror/proxy args.
- [ ] Tests cover env propagation to Codex launch and proxy-env handling for the main application HTTP path where practical.

## Test Cases

- Set `HTTPS_PROXY=http://proxy.example.test:8080` and assert the Linear HTTP client receives or derives proxy configuration.
- Set lowercase `https_proxy` only and assert it is treated as supported.
- Set `NO_PROXY=127.0.0.1,localhost` and assert the value is preserved for child process inheritance.
- Start a Codex app-server test session through the local launch path with proxy env vars set and assert the child environment includes them.
- Assert diagnostics or logs redact proxy credentials such as `user:pass@proxy.example.test`.
- Run existing Linear diagnostics tests without proxy env vars and confirm behavior is unchanged.
- Run existing app-server tests without proxy env vars and confirm launch behavior is unchanged.

## Implementation Notes

- Prefer environment variables as the public contract. They are standard across curl, npm, many HTTP stacks, and container platforms.
- For Symphony's main HTTP requests, inspect Req/Finch proxy support and configure it centrally in `SymphonyElixir.Linear.Client` or a small HTTP options helper.
- Keep proxy handling close to the HTTP boundary rather than scattering env reads throughout the application.
- For local Codex launches, `Port.open` currently starts `bash -lc <codex.command>`. Validate whether inherited OS env already carries the proxy variables. If explicit handling is needed, add it in `SymphonyElixir.Codex.AppServer.start_port/2`.
- Do not require users to include `--config shell_environment_policy.inherit=all` for proxy env propagation unless Codex itself requires it for turn tools. The Codex process should at least receive the proxy env from the OS process environment.
- For remote SSH workers, document that proxy env vars must be set inside the worker container or passed by the SSH environment if the deployment relies on SSH `AcceptEnv`/`SendEnv`.
- If custom CA certificates become necessary, document that as a separate task because it has different security and base-image implications.

## Verification

- [ ] `mise exec -- mix format`
- [ ] `mise exec -- mix test`
- [ ] `mise exec -- mix test --cover`
- [ ] `git diff --check`
- [ ] Manual Docker run with proxy env vars against at least one dashboard target
- [ ] Manual all-in-one run verifies Codex process sees proxy env vars

## Completion Deviations

N/A.

## Dependencies

- Task 022 Linear integration diagnostics, because diagnostics should reveal proxy-affected Linear connectivity without leaking credentials.
- Task 029 Linear workflow state model, because all-in-one proxy support should work with the current default workflow.
- Task 030 Docker image modes, because runtime proxy env docs must cover all Docker targets separately from build-time mirrors.

## Handoff Notes

- Keep build-time and runtime proxy concepts separate:
  - build-time: Docker registry, apt mirror, npm registry, Hex mirror, Docker `HTTP_PROXY` build args;
  - runtime: container/process env vars consumed by Symphony and Codex.
- Do not put proxy URLs in `WORKFLOW.md` unless a deployment explicitly wants workflow-versioned proxy settings.
- Treat proxy URLs as secrets when they include credentials.
