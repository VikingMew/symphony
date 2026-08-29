# SYM-23 workpad

- 2026-08-29: Read the issue and all recent activity before editing. No human
  comment changes the refined scope. Historical implementation comments identify
  `handle_info({:linear_task_update_result, ...})` as the exact pollution path,
  but those edits are absent from the clean required branch, so the fix is being
  recreated and independently verified.
- Container-engine validation is prohibited. Only static Compose review will be
  performed; this does not conflict with the ticket's validation plan.
- Validation environment: targeted tests and `mix specs.check` cannot execute
  because `mix` is absent (exit 127); `make all` cannot execute because `make`
  is absent (exit 127). A repository-local prebuilt OTP option was investigated,
  but no compatible Linux ARM64 artifact was available. `git diff --check` and
  static callback/control, production `:sys`, Compose, and stale-run audits pass.
