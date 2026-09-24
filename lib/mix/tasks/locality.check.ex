defmodule Mix.Tasks.Locality.Check do
  @moduledoc "Checks repository code-locality contracts."

  use Mix.Task

  @shortdoc "Checks repository code-locality contracts"

  @impl Mix.Task
  def run(_args) do
    violations = SymphonyElixir.Locality.check()
    Mix.shell().info(SymphonyElixir.Locality.format(violations))

    if violations != [] do
      Mix.raise("code locality check failed")
    end
  end
end
