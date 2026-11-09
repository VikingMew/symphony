defmodule SymphonyElixir.HostProbe.HostLauncher do
  @moduledoc "Pre-spawn availability check for the operator-selected Codex launcher."

  @type launcher_evidence :: %{kind: String.t(), stage: String.t()}

  @spec preflight_host_launcher(String.t(), (String.t() -> String.t() | nil)) :: :ok | {:error, launcher_evidence()}
  def preflight_host_launcher(command, find_executable \\ &System.find_executable/1) when is_binary(command) do
    executable = command |> OptionParser.split() |> List.first()

    if is_binary(executable) and find_executable.(executable) do
      :ok
    else
      {:error, %{kind: "launcher_unavailable", stage: "pre_spawn"}}
    end
  end
end
