defmodule SymphonyElixir.Worker.Executor do
  @moduledoc "Lease-owned preparation, execution, validation, and handoff pipeline."

  alias SymphonyElixir.Worker.{Command, Config, Paths, Payload, Validation}

  @spec execute(Config.t(), map()) :: map()
  def execute(config, claim) do
    with {:ok, payload} <- Payload.parse(claim["execution"]),
         {:ok, workspace} <- Paths.lease_dir(config, claim["project_id"], claim["task_id"], claim["lease_id"]),
         {:ok, log_dir} <- Paths.log_dir(config, claim["task_id"], claim["lease_id"]),
         :ok <- File.mkdir_p(workspace),
         {:ok, revision} <- prepare(payload, workspace),
         :ok <- run_steps(payload.hooks, workspace, :hook_failed),
         %{status: :passed} <- Command.run(payload.codex, workspace),
         validation <- Validation.run(payload.gates, workspace),
         :passed <- validation.overall_status,
         :ok <- handoff(payload, workspace) do
      summary = summary(config, claim, revision, validation)
      Validation.write!(Path.join(log_dir, "validation.json"), summary)
      Map.merge(summary, %{status: :completed, phase: :handoff})
    else
      {:error, reason} -> %{status: :failed, reason: inspect(reason)}
      %{status: status} = result -> %{status: :failed, reason: status, detail: result.detail}
      status when status in [:failed, :timed_out, :cancelled, :toolchain_unavailable] -> %{status: :failed, reason: status}
    end
  end

  defp prepare(payload, workspace) do
    with %{status: :passed} <- Command.run(%{command: "git clone --no-checkout -- #{shell(payload.repository)} .", timeout_seconds: 300}, workspace),
         %{status: :passed} <- Command.run(%{command: "git checkout --detach #{shell(payload.revision)} && git rev-parse HEAD", timeout_seconds: 120}, workspace),
         {revision, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: workspace) do
      {:ok, String.trim(revision)}
    else
      result -> {:error, {:source_preparation_failed, result}}
    end
  end

  defp run_steps(steps, workspace, failure) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case Command.run(step, workspace) do
        %{status: :passed} -> {:cont, :ok}
        result -> {:halt, {:error, {failure, result}}}
      end
    end)
  end

  defp handoff(%{handoff: %{"command" => command, "timeout_seconds" => timeout}}, workspace) do
    case Command.run(%{command: command, timeout_seconds: timeout}, workspace) do
      %{status: :passed} -> :ok
      result -> {:error, {:handoff_failed, result}}
    end
  end

  defp handoff(_payload, _workspace), do: {:error, :missing_handoff}

  defp summary(config, claim, revision, validation) do
    %{
      envelope: Map.take(claim, ["task_id", "lease_id", "project_id", "run_id"]),
      source_revision: revision,
      runtime_identity: %{image: config.image_reference, worker_source_revision: config.source_revision},
      validation: validation
    }
  end

  defp shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
