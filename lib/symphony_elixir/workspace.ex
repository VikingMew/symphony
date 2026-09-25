defmodule SymphonyElixir.Workspace do
  @moduledoc "Creates isolated per-issue workspaces for parallel Codex agents."

  use SymphonyElixir.Workspace.Sections.Lifecycle
  use SymphonyElixir.Workspace.Sections.Hooks
end
