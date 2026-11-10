defmodule SymphonyElixir.HostProbe.HostExecutor do
  @moduledoc "Runs the existing execution contract from an operator-prepared host workspace."

  alias SymphonyElixir.HostProbe.{HostConfig, HostLauncher, HostWorkspace}
  alias SymphonyElixir.Worker.Executor

  @spec execute_host_assignment(HostConfig.host_config(), map(), (String.t(), map() -> term())) :: map()
  def execute_host_assignment(config, claim, progress) do
    issue_identifier = Map.fetch!(claim, "issue_identifier")

    with {:ok, workspace} <- HostWorkspace.resolve_host_workspace(config.workspace_root, issue_identifier),
         :ok <- HostLauncher.preflight_host_launcher(config.launcher) do
      Executor.execute_prepared(config, claim, workspace, config.launcher, progress)
    else
      {:error, evidence} ->
        %{
          status: :failed,
          phase: :workspace,
          reason: :workspace_unavailable,
          detail: evidence,
          failure_evidence: evidence
        }
    end
  end
end
