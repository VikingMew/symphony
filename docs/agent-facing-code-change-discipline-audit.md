---
title: Agent-Facing Code Change Discipline Audit
genre: reference
domain: [governance, code-quality, agents]
status: current
language: en
owner: docs/agent-facing-code-design.md
updated: 2026-10-14
---

# Agent-Facing Code Change Discipline Audit

This L4 audit records the six C-group clauses before and after the SYM-148 implementation.
It provides repository paths or commands that reproduce each conclusion. The audit supplies
grouped evidence only; the repository still makes no positive nine-group conformance claim.

| Clause | Before implementation | After implementation | Evidence |
| --- | --- | --- | --- |
| C-01 | Partially satisfied: narrow-scope guidance lacked a one-intent commit contract. | Human-review contract now requires one intent per commit and keeps formatting, renames, and functional changes separate. | `AGENTS.md` under `## Required Rules`; `rg -n "Each commit has one intent" AGENTS.md` |
| C-02 | Partially satisfied: public specs, docs, and tests were separate obligations. | Public interface changes explicitly update documentation and tests in the same change. | `AGENTS.md` under `## Required Rules`; `rg -n "Public interface changes" AGENTS.md` |
| C-03 | Satisfied by pre-release rename guidance, with no explicit zero-old-name wording. | Renames require repository-wide old-name removal and prohibit compatibility shims. | `AGENTS.md` under `## Required Rules`; `rg -n "Rename changes" AGENTS.md` |
| C-04 | Partially satisfied: dead branches were discouraged but commented-out dead code was unnamed. | Dead code must be deleted and cannot be retained in comments or commented-out blocks. | `AGENTS.md` under `## Required Rules`; `rg -n "Delete dead code" AGENTS.md` |
| C-05 | Satisfied before and after: formatting is tool-enforced. | The existing format gate remains wired through `scripts/check.sh` and the unified CI quality job. | `scripts/check.sh`; `mix format --check-formatted`; `.github/workflows/make-all.yml` |
| C-06 | Partially satisfied: `change_lines` replayed a fixed 1181 sample. | `git_change_lines` measures the current merge-base diff with default 700 and redline 1500; 2026-10-04 calibration is recorded. | `config/agent_code_governance.yml`; `mix agent_code.check --format json`; targeted checker fixtures |

The dynamic measurement has a zero C-specific baseline and no exemption path. It resolves only
`refs/remotes/origin/HEAD`; missing symbolic refs, target commits, and merge-bases fail explicitly.
