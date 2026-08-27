defmodule Mix.Tasks.Symphony.Build do
  @moduledoc """
  Builds the local Symphony executable wrapper.

  The wrapper keeps the local-development `./bin/symphony` command while
  running the application through Mix. Production containers use an OTP release.
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
