defmodule Mix.Tasks.AgentCodeN.Check do
  use Mix.Task

  alias SymphonyElixir.AgentCodeNCheck

  @shortdoc "Checks Agent-facing code navigation conformance"
  @moduledoc "Runs the deterministic Agent-facing code N-conformance check."

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [format: :string, write_baseline: :boolean])
    format = Keyword.get(opts, :format, "human")

    if argv != [] or invalid != [] or format not in ~w(human json) do
      Mix.raise("Usage: mix agent_code_n.check [--format human|json] [--write-baseline]")
    end

    report =
      if Keyword.get(opts, :write_baseline, false) do
        AgentCodeNCheck.write_navigation_baseline()
      else
        AgentCodeNCheck.check()
      end

    output(report, format)

    if AgentCodeNCheck.exit_code(report) != 0 do
      Mix.raise("agent_code_n.check found navigation conformance failures")
    end
  end

  defp output(report, "json"), do: Mix.shell().info(Jason.encode!(report))
  defp output(report, "human"), do: Mix.shell().info(AgentCodeNCheck.human_output(report))
end
