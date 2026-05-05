defmodule Mix.Tasks.Symphony.Build do
  @moduledoc """
  Builds the local Symphony executable wrapper.

  Symphony depends on SQLite NIFs, which cannot be loaded reliably from an
  escript archive. The wrapper keeps the public `./bin/symphony` command while
  running through Mix so native dependencies load from the build directory.
  """

  use Mix.Task

  @shortdoc "Builds the ./bin/symphony executable wrapper"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("compile")

    bin_dir = Path.expand("bin")
    path = Path.join(bin_dir, "symphony")

    File.mkdir_p!(bin_dir)
    File.write!(path, wrapper_script())
    File.chmod!(path, 0o755)

    Mix.shell().info("Generated #{Path.relative_to_cwd(path)}")
  end

  defp wrapper_script do
    """
    #!/usr/bin/env sh
    set -eu

    script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
    cd "$script_dir/.."

    exec mix run --no-start -e 'SymphonyElixir.CLI.main(System.argv())' -- "$@"
    """
  end
end
