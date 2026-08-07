# Decision Log

### Elixir/Phoenix control plane for the diverged fork

Status: accepted

The fork retained Symphony's orchestration model but diverged into an Elixir/Phoenix control
plane. BEAM supervision fits the long-running orchestration workload, while Phoenix supplies the
operator UI and service boundary without a separate frontend stack.

### SQLite-backed runtime settings

Status: accepted

SQLite workflow versions are the runtime authority, including the selected active version.
`workflow.yml` and `profiles.yml` remain import/export artifacts and examples so runtime behavior
does not depend on ambiguous file fallback or automatic seeding.

### Per-project workflow versions and multi-project runtime

Status: accepted

Each enabled project owns its active workflow version and project-scoped runtime settings. Plans
215-219 established a single orchestrator that iterates those project contexts while preserving
default-project compatibility for existing callers.

### Checked exec-plan lifecycle

Status: accepted

Implementation work is recorded as indexed active or completed exec plans with verification and
handoff evidence. `mix exec_plans.check` enforces index membership so lifecycle state is explicit
and historical plans remain discoverable.

### Quality-gate debt cleanup

Status: accepted

Plans 221-224 treated static-analysis debt as bounded cleanup instead of weakening the gates:
Credo failing-priority findings went to zero, and Dialyzer went from 117 warnings to zero while
preserving the regression suite.

### Promote `elixir/` to the repository root

Status: accepted

The fork is now an Elixir/Phoenix product rather than a repository containing an optional Elixir
implementation. Plan 226 owns the history-preserving promotion of the Elixir project and docs to
the repository root; this decision log does not perform that move.

### Adopt the L0-L5 documentation model

Status: accepted

Documentation is classified into one of six authority layers, with one owning document for each
contract and links elsewhere. Plan 225 establishes the index, metadata seed, and checker before
plan 227 performs naming convergence and the full frontmatter sweep.
