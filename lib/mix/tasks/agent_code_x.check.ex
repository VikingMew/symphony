defmodule Mix.Tasks.AgentCodeX.Check do
  use Mix.Task

  alias SymphonyElixir.AgentCodeXCheck

  @shortdoc "Checks Agent-facing code X conformance"
  @moduledoc "Runs the deterministic Agent-facing code X-conformance check."

  @impl Mix.Task
  def run([]) do
    report = AgentCodeXCheck.check()
    Mix.shell().info(AgentCodeXCheck.human_output(report))

    if AgentCodeXCheck.exit_code(report) != 0 do
      Mix.raise("agent_code_x.check found conformance failures")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix agent_code_x.check")
end
