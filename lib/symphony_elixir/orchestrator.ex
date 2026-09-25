defmodule SymphonyElixir.Orchestrator do
  @moduledoc "Polls Linear and dispatches repository copies to Codex-backed workers."

  use SymphonyElixir.Orchestrator.Sections.Lifecycle
  use SymphonyElixir.Orchestrator.Sections.Completion
  use SymphonyElixir.Orchestrator.Sections.Reconciliation
  use SymphonyElixir.Orchestrator.Sections.Dispatch
  use SymphonyElixir.Orchestrator.Sections.Control
  use SymphonyElixir.Orchestrator.Sections.RuntimeStatus
  use SymphonyElixir.Orchestrator.Sections.Persistence
end
