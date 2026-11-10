defmodule SymphonyElixir.HostProbe.HostRuntime do
  @moduledoc "Single-assignment host-probe registration, lease, execution, and delivery loop."

  require Logger

  alias SymphonyElixir.HostProbe.{HostClient, HostConfig}
  alias SymphonyElixir.Worker.Runtime, as: WorkerRuntime

  @spec start_host_runtime_link(HostConfig.host_config()) :: {:ok, pid()}
  def start_host_runtime_link(config) do
    Task.start_link(fn ->
      schedule_host_message(config, :register, 0)
      run_host_loop(%{config: config, identity: nil, active: nil, heartbeat_seconds: config.heartbeat_seconds})
    end)
  end

  @doc false
  @spec read_host_runtime_state(pid()) :: map()
  def read_host_runtime_state(runtime) do
    ref = make_ref()
    send(runtime, {:read_host_runtime_state, self(), ref})

    receive do
      {:host_runtime_state, ^ref, state} -> state
    end
  end

  defp run_host_loop(state) do
    receive do
      {:read_host_runtime_state, from, ref} ->
        send(from, {:host_runtime_state, ref, state})
        run_host_loop(state)

      message ->
        message
        |> handle_host_message(state)
        |> run_host_loop()
    end
  end

  defp handle_host_message(:register, state) do
    case HostClient.register_host_probe(state.config) do
      {:ok, response} ->
        identity = %{
          "worker_id" => Map.fetch!(response, "worker_id"),
          "session_id" => Map.fetch!(response, "session_id"),
          "protocol_version" => HostClient.host_protocol_version(),
          "execution_surface" => "host_probe",
          "probe_id" => state.config.probe_id,
          "capability_digest" => state.config.capability_digest
        }

        heartbeat_seconds = Map.fetch!(response, "heartbeat_interval_seconds")
        schedule_host_message(state.config, :poll, 0)
        schedule_host_message(state.config, :heartbeat, heartbeat_seconds)
        %{state | identity: identity, heartbeat_seconds: heartbeat_seconds}

      {:error, _reason} ->
        schedule_host_message(state.config, :register, state.config.heartbeat_seconds)
        state
    end
  end

  defp handle_host_message(:poll, %{identity: identity} = state) when is_map(identity) do
    request =
      Map.merge(identity, %{
        "available_slots" => if(state.active, do: 0, else: 1),
        "capabilities" => %{"values" => state.config.capabilities}
      })

    case HostClient.claim_host_assignment(state.config, request) do
      {:ok, %{"task" => nil} = response} ->
        schedule_host_message(state.config, :poll, Map.get(response, "poll_after_seconds", state.config.heartbeat_seconds))
        state

      {:ok, %{"task_id" => _task_id} = claim} when is_nil(state.active) ->
        schedule_host_message(state.config, :poll, state.config.heartbeat_seconds)
        start_host_claim(state, Map.merge(claim, identity))

      {:error, {:http_error, 401, _body}} ->
        recover_host_session(state)

      _other ->
        schedule_host_message(state.config, :poll, state.config.heartbeat_seconds)
        state
    end
  end

  defp handle_host_message(:poll, state), do: state

  defp handle_host_message(:heartbeat, %{identity: identity} = state) when is_map(identity) do
    active_leases =
      case state.active do
        %{phase: :executing, claim: claim} -> [Map.fetch!(claim, "lease_id")]
        _other -> []
      end

    next =
      case HostClient.heartbeat_host_assignment(state.config, identity, %{
             "active_leases" => active_leases,
             "available_slots" => if(state.active, do: 0, else: 1)
           }) do
        {:ok, response} ->
          state
          |> apply_host_renewals(Map.get(response, "lease_renewals", []))
          |> apply_host_commands(Map.get(response, "commands", []))

        {:error, {:http_error, 401, _body}} ->
          recover_host_session(state)

        _other ->
          state
      end

    if next.identity, do: schedule_host_message(next.config, :heartbeat, next.heartbeat_seconds)
    next
  end

  defp handle_host_message(:heartbeat, state), do: state

  defp handle_host_message({ref, result}, %{active: %{ref: ref, phase: :executing}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    begin_host_terminal(state, host_terminal_type(result), result)
  end

  defp handle_host_message({ref, _result}, state) when is_reference(ref), do: state

  defp handle_host_message({:DOWN, ref, :process, _pid, reason}, %{active: %{ref: ref, phase: :executing}} = state)
       when reason != :normal do
    begin_host_terminal(state, "task.failed", %{status: :failed, phase: :codex, reason: reason})
  end

  defp handle_host_message({:DOWN, _ref, :process, _pid, _reason}, state), do: state

  defp handle_host_message({:executor_progress, task_id, phase, payload}, %{active: %{task_id: task_id}} = state) do
    _ = send_runtime_host_event(state, task_id, "task.progress", Map.put(payload, :phase, phase))
    state
  end

  defp handle_host_message({:executor_progress, _task_id, _phase, _payload}, state), do: state

  defp handle_host_message({:local_deadline, task_id, generation}, %{active: active} = state) do
    if active.task_id == task_id and active.deadline_generation == generation and active.phase == :executing do
      Process.exit(active.pid, :shutdown)

      result = %{
        status: :failed,
        phase: :lease,
        reason: :lease_lost,
        failure_evidence: %{kind: "local_deadline_expired", stage: "lease"}
      }

      begin_host_terminal(state, "task.failed", result)
    else
      state
    end
  end

  defp handle_host_message({:retry_terminal, task_id}, %{active: %{task_id: task_id, phase: :delivering}} = state) do
    deliver_host_terminal(state)
  end

  defp handle_host_message({:retry_terminal, _task_id}, state), do: state

  defp start_host_claim(state, claim) do
    runtime = self()
    task_id = Map.fetch!(claim, "task_id")

    task =
      Task.Supervisor.async_nolink(state.config.task_supervisor, fn ->
        progress = fn phase, payload -> send(runtime, {:executor_progress, task_id, phase, payload}) end
        state.config.execute_assignment.(state.config, claim, progress)
      end)

    active = %{
      task_id: task_id,
      claim: claim,
      pid: task.pid,
      ref: task.ref,
      phase: :executing,
      deadline_generation: 0,
      deadline_timer: nil,
      deadline_at_ms: nil,
      attempts: 0
    }

    state
    |> Map.put(:active, active)
    |> arm_host_deadline()
    |> tap(fn next ->
      _ = send_runtime_host_event(next, task_id, "task.progress", %{phase: "execution_started"})
    end)
  end

  defp apply_host_renewals(%{active: %{phase: :executing} = active} = state, renewals) when is_list(renewals) do
    if Enum.any?(renewals, &(&1["lease_id"] == active.claim["lease_id"])), do: arm_host_deadline(state), else: state
  end

  defp apply_host_renewals(state, _renewals), do: state

  defp arm_host_deadline(%{active: active} = state) do
    if active.deadline_timer, do: state.config.cancel_timer.(active.deadline_timer)

    generation = active.deadline_generation + 1
    timeout_ms = state.config.local_deadline_seconds * 1_000
    timer = state.config.send_after.(self(), {:local_deadline, active.task_id, generation}, timeout_ms)

    active = %{
      active
      | deadline_generation: generation,
        deadline_timer: timer,
        deadline_at_ms: state.config.now_ms.() + timeout_ms
    }

    %{state | active: active}
  end

  defp apply_host_commands(state, commands) when is_list(commands) do
    Enum.reduce(commands, state, fn
      %{"type" => "cancel_task", "task_id" => task_id}, %{active: %{task_id: task_id} = active} = current ->
        Process.exit(active.pid, :shutdown)
        begin_host_terminal(current, "task.cancelled", %{status: :cancelled, reason: :operator_requested})

      _command, current ->
        current
    end)
  end

  defp begin_host_terminal(%{active: nil} = state, _type, _result), do: state

  defp begin_host_terminal(state, type, result) do
    active = state.active
    if active.deadline_timer, do: state.config.cancel_timer.(active.deadline_timer)

    payload = %{
      "event_id" => Ecto.UUID.generate(),
      "summary" => WorkerRuntime.host_terminal_summary(result, state.config, active.claim)
    }

    active =
      Map.merge(active, %{
        phase: :delivering,
        deadline_timer: nil,
        terminal_type: type,
        terminal_payload: payload,
        attempts: 0
      })

    state |> Map.put(:active, active) |> deliver_host_terminal()
  end

  defp deliver_host_terminal(state) do
    active = state.active

    case send_runtime_host_event(state, active.task_id, active.terminal_type, active.terminal_payload) do
      {:ok, _response} ->
        %{state | active: nil}

      {:error, reason} ->
        if HostClient.retry_host_terminal?(reason) do
          Logger.warning(
            "Host probe terminal delivery retrying" <>
              " issue_id=#{active.claim["issue_id"]}" <>
              " issue_identifier=#{active.claim["issue_identifier"]}" <>
              " task_id=#{active.task_id}" <>
              " lease_id=#{active.claim["lease_id"]}" <>
              " attempt=#{active.attempts + 1}",
            event: "host_probe.terminal_delivery_retry",
            operation: "deliver_terminal",
            location: "host_probe.worker_v1",
            expected_shape: "acknowledged terminal event",
            error_code: "terminal_delivery_unacknowledged",
            retryable: true,
            issue_id: active.claim["issue_id"],
            issue_identifier: active.claim["issue_identifier"],
            offending_value: inspect(reason, limit: 20, printable_limit: 1_000)
          )

          schedule_host_message(state.config, {:retry_terminal, active.task_id}, state.config.lifecycle_retry_seconds)
          %{state | active: %{active | attempts: active.attempts + 1}}
        else
          %{state | active: nil}
        end
    end
  end

  defp recover_host_session(state) do
    if state.active, do: Process.exit(state.active.pid, :shutdown)
    schedule_host_message(state.config, :register, 0)
    %{state | identity: nil, active: nil}
  end

  defp host_terminal_type(%{status: :completed}), do: "task.completed"
  defp host_terminal_type(%{status: :cancelled}), do: "task.cancelled"
  defp host_terminal_type(_result), do: "task.failed"

  defp send_runtime_host_event(state, task_id, type, payload) do
    HostClient.send_host_event(state.config, state.identity, task_id, type, payload)
  end

  defp schedule_host_message(config, message, seconds) do
    config.send_after.(self(), message, seconds * 1_000)
  end
end
