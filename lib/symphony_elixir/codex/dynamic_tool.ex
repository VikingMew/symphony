defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc "Executes client-side tool calls requested by Codex app-server turns."

  use SymphonyElixir.Codex.DynamicTool.Sections.RequestExecution
  use SymphonyElixir.Codex.DynamicTool.Sections.Updates
end
