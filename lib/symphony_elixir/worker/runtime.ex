defmodule SymphonyElixir.Worker.Runtime do
  @moduledoc false
  use GenServer

  require Logger

  alias SymphonyElixir.Worker.{Cleanup, Config, Paths}

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    Process.send_after(self(), :register, 0)
    Process.send_after(self(), :cleanup, 0)
    {:ok, %{config: config, identity: nil, active: %{}, heartbeat_seconds: 10}}
  end

  @impl true
  def handle_info(:register, state) do
    case client(state).register(state.config) do
      {:ok, response} ->
        identity = %{
          "worker_id" => response["worker_id"],
          "session_id" => response["session_id"],
          "protocol_version" => client(state).protocol_version()
        }

        schedule(:poll, 0)
        heartbeat_seconds = response["heartbeat_interval_seconds"] || 10
        schedule(:heartbeat, heartbeat_seconds)
        {:noreply, %{state | identity: identity, heartbeat_seconds: heartbeat_seconds}}

      {:error, _reason} ->
        schedule(:register, 5)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{identity: identity} = state) when not is_nil(identity) do
    request =
      Map.merge(identity, %{
        "available_slots" => max(state.config.slots - map_size(state.active), 0),
        "capabilities" => %{"execution" => ["v1"]}
      })

    next =
      case client(state).claim(state.config, request) do
        {:ok, %{"task" => nil}} -> state
        {:ok, %{"task_id" => task_id} = claim} -> start_claim(state, task_id, claim)
        {:error, {:http_error, 401, _body}} -> recover_session(state)
        _ -> state
      end

    schedule(:poll, 5)
    {:noreply, next}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(:heartbeat, %{identity: identity} = state) when not is_nil(identity) do
    leases = Enum.map(state.active, fn {_task_id, active} -> active.claim["lease_id"] end)

    next =
      case client(state).heartbeat(state.config, identity, %{
             active_leases: leases,
             available_slots: max(state.config.slots - map_size(state.active), 0)
           }) do
        {:ok, %{"commands" => commands}} when is_list(commands) ->
          commands
          |> Enum.filter(&(&1["type"] == "cancel_task"))
          |> Enum.reduce(state, &cancel/2)

        {:error, {:http_error, 401, _body}} ->
          recover_session(state)

        _ ->
          state
      end

    if next.identity, do: schedule(:heartbeat, next.heartbeat_seconds)
    {:noreply, next}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case find_active(state, ref, nil) do
      {task_id, _active} ->
        Process.demonitor(ref, [:flush])
        {:noreply, begin_terminal_delivery(state, task_id, terminal_type(result), result)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_active(state, ref, pid) do
      {task_id, %{phase: phase} = active} when reason != :normal and phase != :delivering_terminal ->
        status = if Map.get(active, :cancelling, false), do: :cancelled, else: :failed
        type = if status == :cancelled, do: "task.cancelled", else: "task.failed"
        result = %{status: status, reason: inspect(reason)}
        {:noreply, begin_terminal_delivery(state, task_id, type, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:executor_started, task_id, pid}, state) do
    case Map.get(state.active, task_id) do
      %{pid: ^pid, phase: :starting} = active ->
        Process.cancel_timer(active.watchdog)

        with {:ok, _} <- event(state, task_id, "task.accepted", %{phase: "accepted"}),
             {:ok, _} <- event(state, task_id, "task.progress", %{phase: "execution_started"}) do
          send(pid, :execute)
          {:noreply, put_active(state, task_id, %{active | phase: :executing, watchdog: nil})}
        else
          {:error, reason} ->
            Process.exit(pid, :shutdown)
            result = %{status: :failed, reason: inspect(reason)}
            {:noreply, begin_terminal_delivery(state, task_id, "task.failed", result)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:executor_progress, task_id, phase, payload}, state) do
    if Map.has_key?(state.active, task_id) do
      case event(state, task_id, "task.progress", Map.put(payload, :phase, phase)) do
        {:ok, _} -> :ok
        {:error, reason} -> log_delivery_failure(state.active[task_id].claim, "task.progress", reason, 1)
      end
    end

    {:noreply, state}
  end

  def handle_info({:executor_start_timeout, task_id, pid}, state) do
    case Map.get(state.active, task_id) do
      %{pid: ^pid, phase: :starting} ->
        Process.exit(pid, :kill)
        result = %{status: :failed, reason: :executor_start_timeout}
        {:noreply, begin_terminal_delivery(state, task_id, "task.failed", result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_terminal, task_id}, state) do
    case Map.get(state.active, task_id) do
      %{phase: :delivering_terminal} -> {:noreply, deliver_terminal(state, task_id)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(:cleanup, state) do
    active =
      state.active
      |> Enum.flat_map(fn {_task_id, %{claim: claim}} ->
        with {:ok, workspace} <- Paths.lease_dir(state.config, claim["project_id"], claim["task_id"], claim["lease_id"]),
             {:ok, log_dir} <- Paths.log_dir(state.config, claim["task_id"], claim["lease_id"]) do
          [workspace, log_dir]
        else
          _ -> []
        end
      end)
      |> MapSet.new()

    now = DateTime.utc_now()
    workspace_targets = Cleanup.descendants_at_depth(state.config.workspace_root, 3)
    log_targets = Cleanup.descendants_at_depth(state.config.log_root, 2)
    _ = Cleanup.sweep(state.config.workspace_root, workspace_targets, active, state.config.retention_seconds, now)
    _ = Cleanup.sweep(state.config.log_root, log_targets, active, state.config.retention_seconds, now)
    _ = Cleanup.evict_cache(state.config.cache_root, state.config.cache_max_bytes, state.config.retention_seconds, now)
    schedule(:cleanup, 300)
    {:noreply, state}
  end

  defp start_claim(state, task_id, claim) do
    if map_size(state.active) < state.config.slots and not Map.has_key?(state.active, task_id) do
      runtime = self()

      task =
        Task.Supervisor.async_nolink(SymphonyElixir.Worker.TaskSupervisor, fn ->
          execute_claim(runtime, state.config, claim)
        end)

      watchdog =
        Process.send_after(
          self(),
          {:executor_start_timeout, task_id, task.pid},
          state.config.executor_start_timeout_seconds * 1_000
        )

      active = %{ref: task.ref, pid: task.pid, claim: claim, phase: :starting, watchdog: watchdog, attempts: 0}
      put_active(state, task_id, active)
    else
      state
    end
  end

  defp execute_claim(runtime, config, claim) do
    task_id = claim["task_id"]
    send(runtime, {:executor_started, task_id, self()})

    receive do
      :execute ->
        progress = fn phase, payload -> send(runtime, {:executor_progress, task_id, phase, payload}) end
        config.executor_module.execute(config, claim, progress)
    end
  end

  defp begin_terminal_delivery(state, task_id, event_type, result) do
    case Map.get(state.active, task_id) do
      nil ->
        state

      active ->
        if active.watchdog, do: Process.cancel_timer(active.watchdog)

        active =
          Map.merge(active, %{
            phase: :delivering_terminal,
            watchdog: nil,
            terminal_type: event_type,
            terminal_payload: %{summary: terminal_summary(result, state.config)},
            attempts: 0
          })

        state |> put_active(task_id, active) |> deliver_terminal(task_id)
    end
  end

  defp deliver_terminal(state, task_id) do
    active = Map.fetch!(state.active, task_id)
    attempt = active.attempts + 1

    case event(state, task_id, active.terminal_type, active.terminal_payload) do
      {:ok, _} ->
        %{state | active: Map.delete(state.active, task_id)}

      {:error, reason} when attempt < state.config.lifecycle_max_attempts ->
        log_delivery_failure(active.claim, active.terminal_type, reason, attempt)
        schedule({:retry_terminal, task_id}, state.config.lifecycle_retry_seconds)
        put_active(state, task_id, %{active | attempts: attempt})

      {:error, reason} ->
        log_delivery_failure(active.claim, active.terminal_type, reason, attempt)
        %{state | active: Map.delete(state.active, task_id)}
    end
  end

  defp cancel(%{"task_id" => task_id}, state) do
    case Map.get(state.active, task_id) do
      nil ->
        state

      %{pid: pid} = lease ->
        Process.exit(pid, :shutdown)
        put_active(state, task_id, Map.put(lease, :cancelling, true))
    end
  end

  defp cancel(_, state), do: state
  defp terminal_type(%{status: :completed}), do: "task.completed"
  defp terminal_type(%{status: :cancelled}), do: "task.cancelled"
  defp terminal_type(_), do: "task.failed"

  defp terminal_summary(result, config) do
    status = Map.get(result, :status, :failed)
    outcome = if status == :completed, do: "succeeded", else: Atom.to_string(status)
    phase = if status == :completed, do: "complete", else: "validation"
    reason = if status == :completed, do: "completed", else: reason_for(status, result)

    %{
      "phase" => phase,
      "outcome" => outcome,
      "reason" => reason,
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source_revision" => config.source_revision,
      "runtime" => %{"image_tag" => config.image_reference, "worker_source_revision" => config.source_revision},
      "validation_status" => "passed",
      "gates" => [],
      "detail" => inspect(result)
    }
  end

  defp reason_for(:cancelled, _), do: "cancelled"
  defp reason_for(_, %{reason: reason}) when reason in [:timed_out, :handoff_failed], do: Atom.to_string(reason)
  defp reason_for(_, _), do: "worker_error"

  defp recover_session(state) do
    Enum.each(state.active, fn {_task_id, lease} -> Process.exit(lease.pid, :shutdown) end)
    schedule(:register, 0)
    %{state | identity: nil, active: %{}}
  end

  defp find_active(state, ref, pid) do
    Enum.find(state.active, fn {_task_id, active} -> active.ref == ref or active.pid == pid end)
  end

  defp event(state, task_id, type, payload), do: client(state).event(state.config, state.identity, task_id, type, payload)
  defp client(state), do: state.config.client_module
  defp put_active(state, task_id, active), do: %{state | active: Map.put(state.active, task_id, active)}

  defp log_delivery_failure(claim, type, reason, attempt) do
    Logger.warning(
      "Worker lifecycle delivery retrying" <>
        " issue_id=#{claim["issue_id"]}" <>
        " issue_identifier=#{get_in(claim, ["execution", "issue", "identifier"])}" <>
        " task_id=#{claim["task_id"]}" <>
        " lease_id=#{claim["lease_id"]}" <>
        " event_type=#{type}" <>
        " attempt=#{attempt}" <>
        " reason=#{inspect(reason)}"
    )
  end

  defp schedule(message, seconds), do: Process.send_after(self(), message, seconds * 1_000)
end
