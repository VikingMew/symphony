defmodule SymphonyElixir.Worker.Executor do
  @moduledoc "Lease-owned preparation, execution, validation, and handoff pipeline."

  alias SymphonyElixir.Worker.{Command, Config, Paths, Payload, Validation}

  @spec execute(Config.t(), map()) :: map()
  def execute(config, claim) do
    Process.flag(:trap_exit, true)

    with {:ok, payload} <- Payload.parse(claim["execution"]),
         {:ok, workspace} <- Paths.lease_dir(config, claim["project_id"], claim["task_id"], claim["lease_id"]),
         {:ok, log_dir} <- Paths.log_dir(config, claim["task_id"], claim["lease_id"]),
         :ok <- File.mkdir_p(workspace),
         :ok <- not_cancelled(),
         {:ok, revision} <- prepare(payload, workspace),
         :ok <- run_steps(payload.hooks, workspace, :hook_failed),
         :ok <- not_cancelled(),
         %{status: :passed} = codex <- Command.run(payload.codex, workspace),
         {:ok, validation} <- validate(config, claim, revision, codex, payload.gates, workspace, log_dir),
         :ok <- not_cancelled(),
         :ok <- handoff(payload, workspace) do
      summary = summary(config, claim, revision, codex, validation)
      Validation.write!(Path.join(log_dir, "validation.json"), summary)
      Map.merge(summary, %{status: :completed, phase: :handoff})
    else
      :cancelled ->
        %{status: :cancelled, reason: :operator_requested, descendants_reaped: true}

      {:validation_cancelled, summary} ->
        Map.merge(summary, %{status: :cancelled, phase: :validation, descendants_reaped: true})

      {:validation_failed, summary} ->
        Map.merge(summary, %{status: :failed, phase: :validation})

      {:error, reason} ->
        %{status: :failed, reason: inspect(reason)}

      %{status: :cancelled} = result ->
        %{status: :cancelled, reason: :operator_requested, detail: result.detail, descendants_reaped: true}

      %{status: status} = result ->
        %{status: :failed, reason: status, detail: result.detail}

      status when status in [:failed, :timed_out, :cancelled, :toolchain_unavailable] ->
        %{status: :failed, reason: status}
    end
  end

  defp prepare(payload, workspace) do
    with :ok <- not_cancelled(),
         %{status: :passed} <- Command.run(%{command: "git clone --no-checkout -- #{shell(payload.repository)} .", timeout_seconds: 300}, workspace),
         :ok <- not_cancelled(),
         %{status: :passed} <- Command.run(%{command: "git checkout --detach #{shell(payload.revision)} && git rev-parse HEAD", timeout_seconds: 120}, workspace),
         {revision, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: workspace) do
      {:ok, String.trim(revision)}
    else
      :cancelled -> :cancelled
      %{status: :cancelled} = result -> result
      result -> {:error, {:source_preparation_failed, result}}
    end
  end

  defp run_steps(steps, workspace, failure) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      with :ok <- not_cancelled(),
           %{status: :passed} <- Command.run(step, workspace) do
        {:cont, :ok}
      else
        %{status: :cancelled} = result -> {:halt, result}
        :cancelled -> {:halt, %{status: :cancelled, detail: "cancelled before phase"}}
        result -> {:halt, {:error, {failure, result}}}
      end
    end)
  end

  defp run_gate(gate, workspace) do
    case not_cancelled() do
      :ok -> Command.run(gate, workspace)
      :cancelled -> %{status: :cancelled, exit_code: nil, duration_ms: 0, detail: "cancelled before gate"}
    end
  end

  defp validate(config, claim, revision, codex, gates, workspace, log_dir) do
    validation = Validation.run(gates, workspace, &run_gate/2)
    summary = summary(config, claim, revision, codex, validation)
    Validation.write!(Path.join(log_dir, "validation.json"), summary)

    case validation.overall_status do
      :passed -> {:ok, validation}
      :cancelled -> {:validation_cancelled, summary}
      _ -> {:validation_failed, summary}
    end
  end

  defp handoff(%{handoff: %{"command" => command, "timeout_seconds" => timeout}}, workspace) do
    case Command.run(%{command: command, timeout_seconds: timeout}, workspace) do
      %{status: :passed} -> :ok
      result -> {:error, {:handoff_failed, result}}
    end
  end

  defp handoff(_payload, _workspace), do: {:error, :missing_handoff}

  defp summary(config, claim, revision, codex, validation) do
    %{
      envelope: Map.take(claim, ["task_id", "lease_id", "project_id", "run_id"]),
      source_revision: revision,
      runtime_identity: %{image: config.image_reference, worker_source_revision: config.source_revision},
      codex: %{session_id: Map.get(codex, :session_id), duration_ms: codex.duration_ms, outcome: codex.status},
      validation: validation
    }
  end

  defp not_cancelled do
    if Process.get(:worker_cancelled) do
      :cancelled
    else
      receive do
        {:EXIT, from, :shutdown} when is_pid(from) ->
          Process.put(:worker_cancelled, true)
          :cancelled
      after
        0 -> :ok
      end
    end
  end

  defp shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
