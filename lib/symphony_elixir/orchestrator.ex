defmodule SymphonyElixir.Orchestrator do
  @moduledoc false

  use SymphonyElixir.Orchestrator.Sections.Lifecycle
  use SymphonyElixir.Orchestrator.Sections.Completion
  use SymphonyElixir.Orchestrator.Sections.Reconciliation
  use SymphonyElixir.Orchestrator.Sections.Dispatch
  use SymphonyElixir.Orchestrator.Sections.Control
  use SymphonyElixir.Orchestrator.Sections.RuntimeStatus
  use SymphonyElixir.Orchestrator.Sections.OrchestratorPersistence
end
