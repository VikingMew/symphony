defmodule Mix.Tasks.AgentCode.Check do
  use Mix.Task

  alias SymphonyElixir.AgentCodeCheck

  @shortdoc "Checks agent-facing code thresholds"
  @moduledoc "Runs the deterministic agent-facing code conformance check."

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [format: :string])

    if argv != [] or invalid != [] or Keyword.get(opts, :format, "human") not in ~w(human json) do
      Mix.raise("Usage: mix agent_code.check [--format human|json]")
    end

    report = AgentCodeCheck.check()
    output(report, Keyword.get(opts, :format, "human"))

    if AgentCodeCheck.exit_code(report) != 0 do
      Mix.raise("agent_code.check found active conformance failures")
    end
  end

  defp output(report, "json"), do: Mix.shell().info(Jason.encode!(report))
  defp output(report, "human"), do: Mix.shell().info(AgentCodeCheck.human_output(report))
end
