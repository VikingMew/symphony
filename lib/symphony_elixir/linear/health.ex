defmodule SymphonyElixir.Linear.Health do
  @moduledoc """
  Shared, sanitized Linear health summary for dashboard and diagnostics views.
  """

  use Agent

  alias SymphonyElixir.PersistenceProvider
  alias SymphonyElixir.Redaction

  @default_ttl_ms :timer.minutes(15)

  @type status :: :ok | :warning | :error | :unknown | :stale
  @type summary :: map()

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> initial_state() end, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec reset!() :: :ok
  def reset! do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _state -> initial_state() end), else: :ok
  end

  @spec latest(keyword()) :: summary()
  def latest(opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    state = state()
    conclusion = Map.get(state, :conclusion)
    request = Map.get(state, :request)

    cond do
      is_nil(conclusion) ->
        unknown(request)

      stale?(conclusion, now, ttl_ms) ->
        conclusion
        |> Map.merge(%{status: :stale, request: request, stale?: true})
        |> decorate()

      true ->
        Map.put(conclusion, :request, request)
        |> decorate()
    end
  end

  @spec unknown(map() | nil) :: summary()
  def unknown(request \\ nil) do
    %{
      status: :unknown,
      source: nil,
      observed_at: nil,
      project_slug: default_project_slug(),
      candidate_count: nil,
      detail: nil,
      primary: nil,
      conclusion: nil,
      request: request || %{state: :idle, source: nil, detail: nil, observed_at: nil}
    }
    |> decorate()
  end

  @spec from_diagnostics(map() | nil) :: summary()
  def from_diagnostics(nil), do: unknown()

  def from_diagnostics(%{} = diagnostics) do
    diagnostics
    |> conclusion_from_diagnostics()
    |> Map.put(:request, request(:succeeded, :diagnostics, "Diagnostics completed.", Map.get(diagnostics, :ran_at)))
    |> decorate()
  end

  @spec observe_diagnostics(map()) :: :ok
  def observe_diagnostics(%{} = diagnostics) do
    conclusion = conclusion_from_diagnostics(diagnostics)
    request = request(:succeeded, :diagnostics, "Diagnostics completed.", Map.get(diagnostics, :ran_at))

    update(%{conclusion: conclusion, request: request})
  end

  def observe_diagnostics(_diagnostics), do: :ok

  @spec observe_runtime_request(atom(), {:ok, [term()]} | {:error, term()}) :: :ok
  def observe_runtime_request(source, {:ok, items}) when is_list(items) do
    observed_at = DateTime.utc_now()

    conclusion = %{
      status: :ok,
      source: source,
      observed_at: observed_at,
      project_slug: default_project_slug(),
      candidate_count: length(items),
      detail: "Linear #{human_source(source)} succeeded.",
      primary: nil
    }

    update(%{conclusion: conclusion, request: request(:succeeded, source, "Request completed.", observed_at)})
  end

  def observe_runtime_request(source, {:error, reason}) do
    observed_at = DateTime.utc_now()
    detail = "Linear #{human_source(source)} failed: #{safe_reason(reason)}"

    Agent.update(__MODULE__, fn state ->
      state
      |> Map.put(:request, request(:failed, source, detail, observed_at))
      |> maybe_put_error_conclusion(source, detail, observed_at)
    end)
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  def observe_runtime_request(_source, _result), do: :ok

  defp state do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: initial_state()
  end

  defp update(attrs) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &Map.merge(&1, attrs)), else: :ok
  end

  defp initial_state, do: %{conclusion: nil, request: %{state: :idle, source: nil, detail: nil, observed_at: nil}}

  defp conclusion_from_diagnostics(diagnostics) do
    probes = Map.get(diagnostics, :probes, %{})
    statuses = probes |> Map.values() |> Enum.map(&Map.get(&1, :status))
    primary = primary_probe(probes)
    status = status_from_probe_statuses(statuses)

    %{
      status: status,
      source: :diagnostics,
      observed_at: Map.get(diagnostics, :ran_at) || DateTime.utc_now(),
      project_slug: get_in(diagnostics, [:config, :project_slug]) || default_project_slug(),
      candidate_count: diagnostics |> Map.get(:issues, []) |> length(),
      detail: primary |> primary_detail(status) |> sanitize_detail(),
      primary: primary_key(primary),
      run_id: Map.get(diagnostics, :run_id)
    }
  end

  defp status_from_probe_statuses(statuses) do
    cond do
      Enum.any?(statuses, &(&1 == :error)) -> :error
      Enum.any?(statuses, &(&1 == :warning)) -> :warning
      statuses != [] and Enum.all?(statuses, &(&1 in [:ok, :skipped])) -> :ok
      true -> :unknown
    end
  end

  defp primary_probe(probes) do
    Enum.find_value([:api, :project, :states, :candidates, :teams], fn key ->
      probe = Map.get(probes, key)
      if is_map(probe) and Map.get(probe, :status) in [:error, :warning], do: {key, probe}
    end)
  end

  defp primary_detail(nil, :ok), do: "Latest Linear diagnostics did not report blocking issues."
  defp primary_detail(nil, :unknown), do: "No blocking Linear probe result was recorded."
  defp primary_detail(nil, _status), do: "Open Linear diagnostics for details."
  defp primary_detail({key, probe}, _status), do: "#{human_probe(key)}: #{Map.get(probe, :detail) || Map.get(probe, :title) || "check failed"}"

  defp primary_key(nil), do: nil
  defp primary_key({key, _probe}), do: key

  defp request(state, source, detail, observed_at), do: %{state: state, source: source, detail: detail, observed_at: observed_at}

  defp maybe_put_error_conclusion(%{conclusion: nil} = state, source, detail, observed_at) do
    Map.put(state, :conclusion, %{
      status: :error,
      source: source,
      observed_at: observed_at,
      project_slug: default_project_slug(),
      candidate_count: nil,
      detail: detail,
      primary: source
    })
  end

  defp maybe_put_error_conclusion(state, _source, _detail, _observed_at), do: state

  defp decorate(%{} = health) do
    display_status = display_status(health)

    health
    |> Map.put(:display_status, display_status)
    |> Map.put(:label, "Linear #{display_status}")
    |> Map.put(:display_detail, display_detail(health, display_status))
  end

  defp display_status(%{request: %{state: :failed}, status: :ok}), do: :warning
  defp display_status(%{status: status}), do: status

  defp display_detail(%{request: %{state: :failed, detail: detail}}, :warning) when is_binary(detail), do: detail
  defp display_detail(%{status: :stale, detail: detail}, _status), do: "Stale Linear health: #{detail || "refresh diagnostics"}"
  defp display_detail(%{detail: detail}, _status) when is_binary(detail) and detail != "", do: detail
  defp display_detail(_health, :ok), do: "Latest Linear health check did not report blocking issues."
  defp display_detail(_health, :unknown), do: "Open Linear diagnostics to run connectivity and state checks."
  defp display_detail(_health, _status), do: "Open Linear diagnostics for details."

  defp stale?(conclusion, now, ttl_ms) do
    case Map.get(conclusion, :observed_at) do
      %DateTime{} = observed_at -> DateTime.diff(now, observed_at, :millisecond) > ttl_ms
      _other -> false
    end
  end

  defp safe_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 500)
    |> sanitize_detail()
  end

  defp sanitize_detail(detail) do
    detail
    |> Redaction.credentials()
    |> String.replace(~r/(?i)authorization\s+(bearer|basic)\s+\S+/, "Authorization [REDACTED]")
  end

  defp human_source(:candidate_fetch), do: "candidate issue fetch"
  defp human_source(:states_fetch), do: "state fetch"
  defp human_source(source), do: source |> to_string() |> String.replace("_", " ")

  defp human_probe(:api), do: "API"
  defp human_probe(:project), do: "Project"
  defp human_probe(:states), do: "Workflow states"
  defp human_probe(:candidates), do: "Candidate issues"
  defp human_probe(:teams), do: "Teams"

  defp default_project_slug do
    case PersistenceProvider.module().default_project() do
      {:ok, project} -> Map.get(project, :linear_project_slug) || Map.get(project, "linear_project_slug") || "n/a"
      _error -> "n/a"
    end
  rescue
    _exception -> "n/a"
  catch
    _kind, _reason -> "n/a"
  end
end
