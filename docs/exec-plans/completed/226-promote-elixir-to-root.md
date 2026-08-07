# 226 Promote elixir/ to Repository Root

## Goal

Remove the `elixir/` subdirectory by promoting its contents to the repository root, so
the repo root IS the Elixir project (`mix.exs`, `mise.toml`, `Makefile`, `lib/`, `test/`
at root). This kills the "must `cd elixir`" friction for every command and enables the
root-level `docs/` layout of the documentation redesign (plan 227).

## Status

Completed.

## Background

The repository is a fork of upstream openai/symphony whose Elixir implementation lives
under `elixir/`. The fork has fully diverged into an Elixir/Phoenix control plane —
nothing else lives in the repo root except docs and metadata (SPEC/ARCHITECTURE/README
at root, `.github/`, LICENSE, NOTICE). The user's directive: "理论上我们不需要 elixir
这个文件夹了". The only name conflict is `README.md` (root = project overview,
elixir/ = implementation guide); `AGENTS.md` exists only under `elixir/`.

## Scope

- Move tracked files from `elixir/` to root via `git mv` (preserving history):
  `mix.exs`, `mix.lock`, `mise.toml`, `Makefile`, `Dockerfile`, `lib/`, `test/`,
  `config/`, `priv/`, `bin/symphony`, `docs/`, `profiles.yml`, `workflow.yml`,
  `.formatter.exs`, `.dialyzer_ignore.exs`, `.gitignore`, `.dockerignore`,
  `.gitattributes`, `AGENTS.md`, `README.md`.
- Merge root `README.md` (project overview) with `elixir/README.md` (implementation
  guide) into a single root README: keep the overview sections, fold in the
  implementation/run sections, drop duplicated "what is Symphony" prose.
- Move `SPEC.md`, `ARCHITECTURE.md`, `CODE_STRUCTURE.md`, `CODE_STRUCTURE.zh-CN.md`
  into `docs/` (raw move; reorganization of their content is plan 227).
- Update `.github/workflows/make-all.yml` cache paths (`elixir/deps` -> `deps`,
  `elixir/_build` -> `_build`, `elixir/mix.lock` -> `mix.lock`); check
  `pr-description-lint.yml` for paths.
- Root `.gitignore` = promoted `elixir/.gitignore`; verify `bin/` ignore rule does not
  exclude `bin/symphony` (force-add if the file is untracked).
- Build/runtime artifacts (`_build/`, `deps/`, `log/`, `tmp/`, `cover/`,
  `symphony.db*`, `erl_crash.dump`) are gitignored — delete the `elixir/` leftovers
  after moving tracked files, do not move them.
- Update any in-repo command references to `elixir/` paths outside `docs/**` (e.g.
  AGENTS.md env notes, Makefile comments, scripts). Docs-internal `elixir/` references
  are plan 227's job.
- Remove the now-empty `elixir/` directory.

## Out of Scope

- Documentation content reorganization, SPEC split, frontmatter sweep,
  `elixir/`-prefix cleanup inside `docs/**` (plan 227).
- Code refactors; behavior changes; dependency changes.

## Acceptance Criteria

- No `elixir/` directory remains; `git status` clean after commit.
- From repo root: `mise exec -- mix test` -> 664 tests, 0 failures, 2 skipped.
- From repo root: `make all` reaches the same state as before the move (known
  pre-existing blocker: credo `[R]`/`[D]` exit 6 — record as deviation, same as 221).
- `mise exec -- mix docs.check` still passes (seed frontmatter survives the move).
- `git log --follow lib/...` shows history preserved (rename detection).
- No `.github/` workflow references `elixir/`.

## Test Cases

- Fresh clone simulation not required; verify via `git mv` + `git status` rename
  detection and the gates above.
- `make MIX="mise exec -- mix" all` from root (expected to stop at lint exit 6 only).
- `mise exec -- mix exec_plans.check` passes (docs/exec-plans moved with the tree).

## Implementation Notes

- Use `git mv` per tracked file/dir (or `git add -A` after plain mv — either is fine
  as long as renames are detected); never `rm` tracked files.
- README merge: keep root README's structure (What/How/Features), insert elixir/README's
  "Run" and "Architecture" sections; verify with a read-through, not just concatenation.
- The `docs/` move is PHYSICAL ONLY — do not reorganize contents (plan 227).
- `bin/symphony` may be gitignored (`/bin/` rule): check `git ls-files elixir/bin/`
  before moving; if untracked, move it anyway and `git add -f` or add an exception.
- CI: after updating workflows, validate YAML syntax (no runner available — eyeball).

## Verification

Executed by Codex CLI (codex-cli 0.147.0, `--sandbox workspace-write`) and independently
verified by the reviewer outside the sandbox:

- Layout: `elixir/` removed; 529 renames detected (history preserved); root is now the
  Elixir project (`mix.exs`, `mise.toml`, `Makefile`, `lib/`, `test/`, `docs/` at root).
- `mise exec -- mix test` (root) -> 664 tests, 0 failures, 2 skipped. One real regression
  found and fixed: `core_test.exs` asserted the old `cd elixir && ...` workflow.yml
  setup/cleanup commands; assertions updated to the promoted commands.
- `mise exec -- mix docs.check` (root) -> 5 passed, 18 skipped, 0 failed.
- `mise exec -- mix exec_plans.check` (root) -> all indexed.
- `mise exec -- mix compile --warnings-as-errors` -> pass.
- `make MIX="mise exec -- mix" all` (root) -> stops at lint as expected (known pre-existing
  credo `[R]`/`[D]` exit 6); one new `[F]` from plan 225's docs.check.ex (cond with single
  condition) found and fixed (cond -> if); credo back to zero `[F]`.
- `.github/` grep for `elixir/` -> no matches; workflows use root paths.
- `bin/symphony` executable at root, tracked (`.gitignore` exception added).
- `.codex/skills/debug/SKILL.md` two stale `elixir/docs/` references fixed (sandbox
  couldn't write `.codex`; reviewer fixed post-run).
- `mise trust` recorded for the promoted root `mise.toml`.
- Residual `elixir/` mentions in `docs/ARCHITECTURE.md` (3) and historical
  `docs/exec-plans/completed/**` are intentionally left for plan 227 (docs-internal
  prefix cleanup) and never-touch historical records respectively.

## Completion Deviations

- Codex could not run the mix gates in-sandbox (Mix.PubSub TCP socket denial) and could
  not commit (`.git/index.lock: Operation not permitted`); all moves were staged. The
  reviewer ran the full gate sequence outside the sandbox, fixed the core_test regression,
  the docs.check.ex credo `[F]`, and the `.codex` path references, then committed.
- `workflow.yml` (import/export artifact) setup/cleanup commands updated to drop
  `cd elixir` — behavior-equivalent for the promoted layout, asserted by core_test.

## Dependencies

- Plan 225 (docs.check + AGENTS.md layer model exist before the move so they can be
  verified post-move).
- Plan 227 consumes this plan's layout (root docs/).

## Handoff Notes

Codex delegation candidate with a strict whitelist: the move is mechanical but
history-sensitive. Prompt must include: the exact tracked-file list, "git mv only,
never rm tracked files", "delete only gitignored artifact dirs", README merge
instructions (read both first), and the verification sequence. Sandbox note: run
`mix test`/`make` directly (network-blocked `make all` setup is a known blocker —
record where it stops). Do NOT touch `docs/**` content.
