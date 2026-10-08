defmodule Mix.Tasks.Observability.Check do
  @moduledoc "Runs the deletion-only observability source conformance gate."

  use Mix.Task

  @shortdoc "Checks structured observability and error-handling debt"

  @impl Mix.Task
  def run([]) do
    report = SymphonyElixir.ObservabilityCheck.check()
    Mix.shell().info(SymphonyElixir.ObservabilityCheck.human_output(report))
    if SymphonyElixir.ObservabilityCheck.exit_code(report) == 1, do: exit({:shutdown, 1})
  end

  def run(_args), do: Mix.raise("usage: mix observability.check")
end
