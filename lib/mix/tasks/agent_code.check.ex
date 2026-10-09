defmodule Mix.Tasks.AgentCode.Check do
  use Mix.Task

  alias SymphonyElixir.AgentCodeCheck

  @shortdoc "Checks agent-facing code governance"
  @moduledoc "Runs the deterministic agent-facing code governance check, source list, or source stats."

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [format: :string])
    format = Keyword.get(opts, :format, "human")
    command = parse_agent_code_mode(argv)

    if invalid != [] or format not in ~w(human json) do
      Mix.raise(agent_code_usage())
    end

    execute_agent_code_mode(command, format)
  end

  defp parse_agent_code_mode([]), do: "check"
  defp parse_agent_code_mode([command]) when command in ~w(check list stats), do: command
  defp parse_agent_code_mode(_argv), do: Mix.raise(agent_code_usage())

  defp execute_agent_code_mode("check", format) do
    report = AgentCodeCheck.check()
    output(report, format)

    if AgentCodeCheck.exit_code(report) != 0 do
      Mix.raise("agent_code.check found active conformance failures")
    end
  end

  defp execute_agent_code_mode("list", format) do
    report = AgentCodeCheck.source_list()
    output_source_list(report, format)
  end

  defp execute_agent_code_mode("stats", format) do
    report = AgentCodeCheck.source_stats()
    output_source_stats(report, format)
  end

  defp output(report, "json"), do: Mix.shell().info(Jason.encode!(report))
  defp output(report, "human"), do: Mix.shell().info(AgentCodeCheck.human_output(report))

  defp output_source_list(report, "json"), do: Mix.shell().info(Jason.encode!(report))
  defp output_source_list(report, "human"), do: Mix.shell().info(Enum.join(report["paths"], "\n"))

  defp output_source_stats(report, "json"), do: Mix.shell().info(Jason.encode!(report))

  defp output_source_stats(report, "human") do
    summary = report["summary"]

    Mix.shell().info(
      "agent_code sources: tracked=#{summary["tracked"]} handwritten=#{summary["handwritten"]} " <>
        "excluded=#{summary["excluded"]} handwritten_lines=#{summary["handwritten_lines"]}"
    )
  end

  defp agent_code_usage, do: "Usage: mix agent_code.check [check|list|stats] [--format human|json]"
end
