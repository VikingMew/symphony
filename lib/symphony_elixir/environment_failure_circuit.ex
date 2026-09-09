defmodule SymphonyElixir.EnvironmentFailureCircuit do
  @moduledoc """
  Tracks repeated environment-shaped failures across issues and opens a dispatch circuit.
  """

  use GenServer

  @threshold 3
  @window_ms 30 * 60 * 1_000
  @event_type "environment_failure_circuit.opened"

  @type snapshot :: %{
          required(:status) => :allow | :tripped,
          required(:active) => boolean(),
          required(:triggering_fingerprint) => String.t() | nil,
          required(:triggered_at) => DateTime.t() | nil,
          required(:threshold) => pos_integer(),
          required(:window_ms) => pos_integer(),
          required(:consecutive_failures) => non_neg_integer(),
          required(:distinct_issue_count) => non_neg_integer(),
          required(:issue_identifiers) => [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec threshold() :: pos_integer()
  def threshold, do: @threshold

  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @spec event_type() :: String.t()
  def event_type, do: @event_type

  @spec fingerprint(term()) :: String.t()
  def fingerprint(reason) do
    normalized = normalize_reason(reason)
    digest = :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    "env_failure:" <> digest
  end

  @spec record_failure(String.t(), term(), map(), GenServer.server()) :: snapshot()
  def record_failure(issue_identifier, reason, metadata \\ %{}, server \\ __MODULE__)
      when is_binary(issue_identifier) and is_map(metadata) do
    GenServer.call(server, {:record_failure, issue_identifier, fingerprint(reason), metadata})
  end

  @spec record_success(String.t(), GenServer.server()) :: snapshot()
  def record_success(issue_identifier, server \\ __MODULE__) when is_binary(issue_identifier) do
    GenServer.call(server, {:record_success, issue_identifier})
  end

  @spec check(GenServer.server()) :: :allow | {:block, snapshot()}
  def check(server \\ __MODULE__) do
    case snapshot(server) do
      %{active: true} = circuit -> {:block, circuit}
      _snapshot -> :allow
    end
  end

  @spec reset(GenServer.server()) :: snapshot()
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec allow_snapshot() :: snapshot()
  def allow_snapshot do
    snapshot_from_state(initial_state(&DateTime.utc_now/0))
  end

  @spec alert_event_attrs(snapshot(), String.t() | nil) :: map()
  def alert_event_attrs(snapshot, project_id \\ nil) when is_map(snapshot) do
    attrs = %{
      project_id: project_id,
      run_id: nil,
      issue_identifier: nil,
      event_type: @event_type,
      payload: Map.delete(snapshot, :alert)
    }

    if is_nil(project_id), do: Map.delete(attrs, :project_id), else: attrs
  end

  @impl true
  def init(opts) do
    {:ok, initial_state(Keyword.get(opts, :now, &DateTime.utc_now/0))}
  end

  @impl true
  def handle_call({:record_failure, issue_identifier, fingerprint, metadata}, _from, state) do
    now = state.now.()

    if state.status == :tripped do
      {:reply, state |> snapshot_from_state() |> Map.put(:alert, false), state}
    else
      failure = failure_entry(issue_identifier, metadata, now)
      failures = next_failures(state, fingerprint, failure, now)

      state =
        %{
          state
          | fingerprint: fingerprint,
            failures: failures
        }
        |> maybe_trip(now)

      {:reply, alert_snapshot(state), state}
    end
  end

  @impl true
  def handle_call({:record_success, _issue_identifier}, _from, %{status: :tripped} = state),
    do: {:reply, snapshot_from_state(state), state}

  def handle_call({:record_success, _issue_identifier}, _from, state) do
    state = %{state | fingerprint: nil, failures: []}
    {:reply, snapshot_from_state(state), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    state = initial_state(state.now)
    {:reply, snapshot_from_state(state), state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from_state(state), state}

  defp initial_state(now) when is_function(now, 0) do
    %{
      status: :allow,
      fingerprint: nil,
      failures: [],
      tripped_at: nil,
      alert: false,
      now: now
    }
  end

  defp failure_entry(issue_identifier, metadata, occurred_at) do
    %{
      issue_identifier: issue_identifier,
      issue_id: Map.get(metadata, :issue_id),
      run_id: Map.get(metadata, :run_id),
      occurred_at: occurred_at
    }
  end

  defp next_failures(%{fingerprint: fingerprint, failures: failures}, fingerprint, failure, now) do
    failures
    |> Enum.filter(&within_window?(&1, now))
    |> Kernel.++([failure])
  end

  defp next_failures(_state, _fingerprint, failure, _now), do: [failure]

  defp within_window?(%{occurred_at: occurred_at}, now) do
    DateTime.diff(now, occurred_at, :millisecond) <= @window_ms
  end

  defp maybe_trip(state, now) do
    if distinct_issue_count(state.failures) >= @threshold do
      %{state | status: :tripped, tripped_at: now, alert: true}
    else
      %{state | alert: false}
    end
  end

  defp alert_snapshot(state), do: state |> snapshot_from_state() |> Map.put(:alert, state.alert)

  defp snapshot_from_state(state) do
    %{
      status: state.status,
      active: state.status == :tripped,
      triggering_fingerprint: state.fingerprint,
      triggered_at: state.tripped_at,
      threshold: @threshold,
      window_ms: @window_ms,
      consecutive_failures: length(state.failures),
      distinct_issue_count: distinct_issue_count(state.failures),
      issue_identifiers: issue_identifiers(state.failures)
    }
  end

  defp distinct_issue_count(failures), do: failures |> issue_identifiers() |> length()

  defp issue_identifiers(failures) do
    failures
    |> Enum.map(& &1.issue_identifier)
    |> Enum.uniq()
  end

  defp normalize_reason(reason) do
    reason
    |> reason_text()
    |> String.downcase()
    |> String.replace(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "<uuid>")
    |> String.replace(~r/\b\d+\b/, "<number>")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason, limit: 20, printable_limit: 1_000)
end
