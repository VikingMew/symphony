defmodule SymphonyElixir.Worker.ExecutionWorkspace do
  @moduledoc "Selects the workspace authority for an assigned execution surface."

  alias SymphonyElixir.HostProbe.PreparedWorkspace
  alias SymphonyElixir.Worker.{Config, Paths, Payload}

  @spec resolve_for_execution(Config.t(), map(), Payload.t(), (String.t(), map() -> term())) ::
          {:ok, Path.t(), map(), list()} | {:error, term()}
  def resolve_for_execution(%Config{execution_surface: "host_probe"} = config, _claim, payload, _progress) do
    with {:ok, workspace} <- PreparedWorkspace.locate(config.workspace_root, payload.codex.issue.identifier) do
      source = %{
        prepared_head: "host-prepared",
        workspace_authority: "host_probe",
        issue_identifier: payload.codex.issue.identifier,
        task_branch: payload.branch,
        default_branch: payload.default_branch
      }

      {:ok, workspace, source, []}
    end
  end

  def resolve_for_execution(config, claim, payload, progress) do
    with {:ok, workspace} <- Paths.lease_dir(config, claim["project_id"], claim["task_id"], claim["lease_id"]),
         :ok <- File.mkdir_p(workspace),
         {:ok, source} <- config.executor_module.prepare(payload, workspace, progress) do
      {:ok, workspace, source, payload.hooks}
    end
  end
end
