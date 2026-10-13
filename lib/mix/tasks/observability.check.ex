defmodule Mix.Tasks.Observability.Check do
  @moduledoc "Runs the deletion-only observability source conformance gate."

  use Mix.Task

  @shortdoc "Checks structured observability and error-handling debt"

  @impl Mix.Task
  def run([]), do: execute_observability_check(false)

  def run(_args) do
    args = Keyword.fetch!(binding(), :_args)
    {opts, argv, invalid} = OptionParser.parse(args, strict: [write_baseline: :boolean])

    if argv != [] or invalid != [] or not Keyword.get(opts, :write_baseline, false) do
      Mix.raise("usage: mix observability.check [--write-baseline]")
    end

    execute_observability_check(true)
  end

  defp execute_observability_check(write_baseline?) do
    report =
      if write_baseline? do
        SymphonyElixir.ObservabilityCheck.write_observability_baseline()
      else
        SymphonyElixir.ObservabilityCheck.check()
      end

    Mix.shell().info(SymphonyElixir.ObservabilityCheck.human_output(report))
    if SymphonyElixir.ObservabilityCheck.exit_code(report) == 1, do: exit({:shutdown, 1})
  end
end
