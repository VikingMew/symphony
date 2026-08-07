# 159 Reverse Proxy and Kubernetes Deployment

## Goal

Make Symphony safe and straightforward to run behind Nginx, Kubernetes Ingress, or another reverse proxy so the application does not need to own public domain, TLS certificate, or edge routing support itself.

Symphony should accept trusted proxy-provided request context and expose enough health/runtime information for Nginx/Kubernetes to route, monitor, and operate it.

## Status

Completed.

## Background

Operators may want to deploy Symphony inside an existing infrastructure boundary:

- Nginx terminates TLS and forwards HTTP/WebSocket traffic to Symphony.
- Kubernetes Ingress handles domain, TLS, path routing, and client-facing headers.
- Symphony runs as an internal service without direct public TLS or domain ownership.

In this model, Symphony should not require its own standalone TLS support or dedicated domain logic. It should be proxy-aware:

- generate correct URLs behind `X-Forwarded-*` headers;
- support LiveView/WebSocket upgrades through a proxy;
- expose health/readiness endpoints;
- avoid trusting spoofed forwarded headers unless explicitly configured;
- provide clear deployment documentation and examples for Nginx/Kubernetes.

The desired contract is: Nginx/Kubernetes owns edge concerns; Symphony owns application behavior and reports enough state for the platform to route and monitor it.

## Scope

- Define and implement reverse-proxy awareness for Symphony web runtime:
  - trusted forwarded host;
  - forwarded proto/scheme;
  - forwarded port;
  - forwarded prefix/path base when mounted under a subpath;
  - real client IP where needed for logs/audit.
- Add or document explicit configuration for proxy mode:
  - enable/disable trusting forwarded headers;
  - allowed/trusted proxy CIDRs or headers;
  - public URL/base URL when headers are not enough.
- Ensure LiveView/WebSocket routes work behind Nginx and Kubernetes Ingress.
- Add health endpoints suitable for platform probes:
  - liveness;
  - readiness;
  - optionally startup.
- Include useful readiness signals:
  - web process up;
  - database reachable/migrated;
  - required runtime setup state if applicable;
  - dependency failures reported clearly without exposing secrets.
- Add deployment documentation/examples:
  - Nginx reverse proxy config;
  - Kubernetes Service/Ingress sketch;
  - required headers;
  - WebSocket upgrade settings;
  - health probe paths;
  - TLS termination guidance.
- Add tests for forwarded header handling and health endpoints.

## Out of Scope

- Do not implement certificate issuance or ACME.
- Do not require Symphony to terminate public TLS.
- Do not require a dedicated public domain per Symphony instance.
- Do not add a full Helm chart unless a later deployment plan owns it.
- Do not implement Kubernetes operator/controller behavior.
- Do not trust forwarded headers by default from arbitrary clients.
- Do not expose secrets in health/readiness responses.

## Acceptance Criteria

- Symphony can run behind Nginx with TLS terminated at Nginx.
- Symphony can run behind Kubernetes Ingress with TLS terminated at Ingress.
- LiveView/WebSocket traffic works through the documented proxy settings.
- Generated links and redirects use the externally visible scheme/host when proxy mode is configured.
- Health endpoints are available and return stable machine-readable responses.
- Readiness reports database/setup availability without leaking secrets.
- Forwarded headers are ignored unless proxy trust is explicitly enabled or safely configured.
- Documentation gives copyable Nginx and Kubernetes examples.
- Tests cover forwarded proto/host/prefix handling and health endpoint behavior.

## Test Cases

- Forwarded proto/host:
  - request arrives internally as `http://127.0.0.1:4000`;
  - headers indicate `https://symphony.example.com`;
  - generated external URL/redirect uses `https://symphony.example.com`.
- Forwarded prefix:
  - proxy mounts app at `/symphony`;
  - app routes, static assets, LiveView, and links work with prefix configuration.
- WebSocket proxy:
  - LiveView socket endpoint accepts upgrade through forwarded proxy headers.
- Untrusted forwarded headers:
  - when proxy trust is disabled, spoofed `X-Forwarded-Host` does not affect generated URLs.
- Liveness:
  - endpoint returns success when web process is serving.
- Readiness success:
  - endpoint returns ready when database/runtime prerequisites are available.
- Readiness failure:
  - endpoint returns non-ready with sanitized reason when database/setup is unavailable.
- Documentation smoke check:
  - examples include `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-For`, and WebSocket upgrade headers.

## Implementation Notes

Start by identifying the current Phoenix endpoint/runtime URL configuration. The implementation should likely involve:

- endpoint `url` and `check_origin` configuration;
- Plug/Phoenix forwarded header support;
- a small health controller or plug;
- explicit app config/env vars for proxy trust and public URL;
- docs in the Elixir README or deployment docs.

Possible configuration names:

```text
SYMPHONY_PROXY_MODE=true
SYMPHONY_PUBLIC_URL=https://example.com/symphony
SYMPHONY_TRUST_X_FORWARDED_HEADERS=true
SYMPHONY_TRUSTED_PROXY_CIDRS=10.0.0.0/8,127.0.0.1/32
```

Keep security conservative. The app should not blindly trust `X-Forwarded-*` from any direct client unless an operator opts in and constrains the proxy boundary.

For Kubernetes:

- expose a ClusterIP Service to the Phoenix port;
- configure Ingress for HTTP and WebSocket traffic;
- readiness/liveness probes should hit internal health endpoints;
- TLS should be owned by Ingress/cert-manager or platform policy, not Symphony.

For Nginx:

- set `proxy_set_header Host $host`;
- set `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-Port`, `X-Forwarded-For`;
- support `Upgrade` and `Connection` headers for WebSockets;
- document subpath routing limitations/requirements if supported.

## Verification

- `mise exec -- mix format`
- Focused endpoint/proxy header tests.
- Focused health endpoint tests.
- LiveView/socket proxy configuration test where feasible.
- Documentation examples for Nginx and Kubernetes.
- Manual or rendered smoke evidence:
  - app behind local Nginx or equivalent reverse proxy;
  - health probes;
  - LiveView connection through proxy.
- `mise exec -- mix exec_plans.check`
- `git diff --check`

## Completion Deviations

Implemented explicit forwarded header trust with `SymphonyElixirWeb.ProxyHeaders`, health probe endpoints, and deployment docs. Readiness treats database/persistence availability as the hard platform signal and reports workflow setup state separately so an unconfigured alpha instance can still expose Settings.

## Dependencies

- Existing Phoenix endpoint/router.
- Existing Docker image/deployment documentation from completed plan 030.
- Existing database/setup runtime configuration.

## Handoff Notes

Keep edge ownership outside Symphony. The application should be proxy-aware and health-checkable, but Nginx/Kubernetes should own public TLS, domain routing, and ingress policy.
