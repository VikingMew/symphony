defmodule SymphonyElixir.StatusDashboard do
  @moduledoc """
  Observes orchestrator status for Web dashboard updates.

  Terminal output is intentionally handled through normal Logger call sites in
  the runtime modules, not by rendering periodic status snapshots here.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.WorkflowStore
  alias SymphonyElixirWeb.ObservabilityPubSub

  defstruct [
    :refresh_ms,
    :enabled,
    :render_interval_ms,
    :refresh_ms_override,
    :enabled_override,
    :render_interval_ms_override,
    :last_snapshot_fingerprint
  ]

  @type t :: %__MODULE__{
          refresh_ms: pos_integer(),
          enabled: boolean(),
          render_interval_ms: pos_integer(),
          refresh_ms_override: pos_integer() | nil,
          enabled_override: boolean() | nil,
          render_interval_ms_override: pos_integer() | nil,
          last_snapshot_fingerprint: term() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify_update(GenServer.name()) :: :ok
  def notify_update(server \\ __MODULE__) do
    ObservabilityPubSub.broadcast_update()

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, :refresh)
        :ok

      _ ->
        :ok
    end
  end

  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    refresh_ms_override = keyword_override(opts, :refresh_ms)
    enabled_override = keyword_override(opts, :enabled)
    render_interval_ms_override = keyword_override(opts, :render_interval_ms)
    observability = configured_observability()
    refresh_ms = refresh_ms_override || observability.refresh_ms
    render_interval_ms = render_interval_ms_override || observability.render_interval_ms
    enabled = resolve_override(enabled_override, observability.dashboard_enabled and dashboard_enabled?())
    schedule_tick(refresh_ms, enabled)

    {:ok,
     %__MODULE__{
       refresh_ms: refresh_ms,
       enabled: enabled,
       render_interval_ms: render_interval_ms,
       refresh_ms_override: refresh_ms_override,
       enabled_override: enabled_override,
       render_interval_ms_override: render_interval_ms_override,
       last_snapshot_fingerprint: nil
     }}
  end

  @spec render_offline_status() :: :ok
  def render_offline_status do
    Logger.error("Symphony application offline")
    :ok
  end

  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:tick, %{enabled: true} = state) do
    state = refresh_runtime_config(state)
    state = maybe_render(state)
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:refresh, %{enabled: true} = state), do: {:noreply, maybe_render(refresh_runtime_config(state))}
  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info(:tick, state), do: {:noreply, state}

  defp refresh_runtime_config(%__MODULE__{} = state) do
    observability = configured_observability()

    %{
      state
      | enabled: resolve_override(state.enabled_override, observability.dashboard_enabled and dashboard_enabled?()),
        refresh_ms: state.refresh_ms_override || observability.refresh_ms,
        render_interval_ms: state.render_interval_ms_override || observability.render_interval_ms
    }
  end

  defp configured_observability do
    raw_observability = raw_observability_config()

    %{
      dashboard_enabled: raw_boolean(raw_observability, "dashboard_enabled", true),
      refresh_ms: raw_positive_integer(raw_observability, "refresh_ms", 1_000),
      render_interval_ms: raw_positive_integer(raw_observability, "render_interval_ms", 16)
    }
  end

  defp raw_observability_config do
    with {:ok, %{config: config}} <- WorkflowStore.current(),
         observability when is_map(observability) <-
           SymphonyElixir.Payload.get_any(config, ["observability", :observability]) do
      observability
    else
      _ -> %{}
    end
  end

  defp raw_boolean(map, key, default) do
    case raw_value(map, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp raw_positive_integer(map, key, default) do
    case raw_value(map, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp raw_value(map, key) do
    SymphonyElixir.Payload.get_any(map, [key, observability_key(key)])
  end

  defp observability_key("dashboard_enabled"), do: :dashboard_enabled
  defp observability_key("refresh_ms"), do: :refresh_ms
  defp observability_key("render_interval_ms"), do: :render_interval_ms
  defp observability_key(_key), do: :__unknown_observability_key__

  defp schedule_tick(refresh_ms, true), do: Process.send_after(self(), :tick, refresh_ms)
  defp schedule_tick(_refresh_ms, false), do: :ok

  defp maybe_render(state) do
    snapshot_data = snapshot_payload()
    fingerprint = loggable_fingerprint(snapshot_data)

    state
    |> maybe_log_snapshot_unavailable(snapshot_data, fingerprint)
    |> maybe_update_snapshot_fingerprint(fingerprint)
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed refreshing status dashboard: #{Exception.message(error)}")
      state
  end

  defp maybe_log_snapshot_unavailable(state, :error, fingerprint)
       when fingerprint != state.last_snapshot_fingerprint do
    Logger.error("Orchestrator snapshot unavailable")
    state
  end

  defp maybe_log_snapshot_unavailable(state, _snapshot_data, _fingerprint), do: state

  defp maybe_update_snapshot_fingerprint(state, fingerprint) do
    if fingerprint == state.last_snapshot_fingerprint do
      state
    else
      Map.put(state, :last_snapshot_fingerprint, fingerprint)
    end
  end

  defp loggable_fingerprint({:ok, %{running: running, retrying: retrying, rate_limits: rate_limits}}) do
    %{
      running:
        Enum.map(running, fn running_entry ->
          %{
            identifier: running_entry.identifier,
            state: running_entry.state,
            session_id: running_entry.session_id,
            pid: running_entry.codex_app_server_pid,
            tokens: running_entry.codex_total_tokens,
            event: running_entry.last_codex_event,
            message: summarize_message(running_entry.last_codex_message)
          }
        end),
      retrying:
        Enum.map(retrying, fn retry ->
          %{
            identifier: retry.identifier,
            attempt: retry.attempt,
            due_in_ms: retry.due_in_ms,
            error: sanitize_retry_error(retry.error || "retry scheduled")
          }
        end),
      rate_limits: rate_limits
    }
  end

  defp loggable_fingerprint(:error), do: :snapshot_unavailable

  @doc """
  Formats a runtime snapshot for the optional terminal status dashboard.

  The current runtime intentionally renders no terminal dashboard content
  because plain logs and the web dashboard own operator status presentation.
  """
  @spec format_snapshot_content(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content(_snapshot_data, _tps, _terminal_columns_override \\ nil), do: ""

  defp sanitize_retry_error(error) when is_binary(error) do
    error
    |> String.replace("\\r\\n", " ")
    |> String.replace("\\r", " ")
    |> String.replace("\\n", " ")
    |> String.replace("\r\n", " ")
    |> String.replace("\r", " ")
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_retry_error(_error), do: "retry scheduled"

  defp snapshot_payload do
    if Process.whereis(Orchestrator) do
      case Orchestrator.snapshot() do
        %{
          running: running,
          retrying: retrying,
          codex_totals: codex_totals
        } = snapshot
        when is_list(running) and is_list(retrying) ->
          {:ok,
           %{
             running: running,
             retrying: retrying,
             codex_totals: codex_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp summarize_message(message), do: SymphonyElixir.Codex.MessageHumanizer.humanize_codex_message(message)

  defp dashboard_enabled? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() != :test
      rescue
        _ -> true
      end
    else
      true
    end
  end

  defp keyword_override(opts, key) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: nil
  end

  defp resolve_override(nil, default), do: default
  defp resolve_override(override, _default), do: override
end
