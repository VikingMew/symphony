defmodule SymphonyElixir.ObservabilityHistory do
  @moduledoc """
  Bounded persisted issue, run, and event reads for the observability API.

  This boundary intentionally does not cache history. Each request runs outside
  runtime snapshot owners through the configured persistence module.
  """

  alias SymphonyElixir.{EventPresenter, PersistenceProvider}

  @default_run_limit 20
  @max_run_limit 50
  @event_limit 100
  @history_timeout_ms 1_000

  @type error :: :repo_unavailable | :timeout | {:query_failed, term()}
  @type history :: %{
          issue_identifier: String.t(),
          issue: map() | nil,
          latest_run: map() | nil,
          runs: [map()],
          events: [map()],
          known?: boolean()
        }

  @spec parse_limit(term()) :: {:ok, pos_integer()} | {:error, :invalid_limit}
  def parse_limit(nil), do: {:ok, @default_run_limit}
  def parse_limit(""), do: {:error, :invalid_limit}

  def parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> {:ok, min(limit, @max_run_limit)}
      _invalid -> {:error, :invalid_limit}
    end
  end

  def parse_limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, @max_run_limit)}
  def parse_limit(_value), do: {:error, :invalid_limit}

  @spec fetch(String.t(), keyword()) :: {:ok, history()} | {:error, error()}
  def fetch(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    timeout = Keyword.get(opts, :timeout, @history_timeout_ms)
    limit = Keyword.get(opts, :limit, @default_run_limit) |> min(@max_run_limit) |> max(1)

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        read_history(issue_identifier, limit)
      end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:query_failed, reason}}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp read_history(issue_identifier, limit) do
    persistence = PersistenceProvider.module()

    with {:ok, issue} <- read_one(fn -> persistence.get_issue_by_identifier(issue_identifier) end),
         {:ok, runs} <- read_list(fn -> persistence.list_runs_for_issue(issue_identifier, limit: limit) end),
         {:ok, events} <-
           read_list(fn ->
             persistence.list_events(
               issue_identifier: issue_identifier,
               limit: @event_limit,
               order: :desc
             )
           end) do
      run_payloads = runs |> newest_runs() |> Enum.take(limit) |> Enum.map(&run_payload/1)
      event_payloads = events |> newest_events() |> Enum.take(@event_limit) |> Enum.map(&event_payload/1)

      {:ok,
       %{
         issue_identifier: issue_identifier,
         issue: issue_payload(issue),
         latest_run: List.first(run_payloads),
         runs: run_payloads,
         events: event_payloads,
         known?: is_map(issue) or run_payloads != []
       }}
    end
  end

  defp read_one(fun) do
    case PersistenceProvider.read(fun) do
      {:error, :repo_unavailable} = error -> error
      {:error, {:query_failed, _reason}} = error -> error
      value -> {:ok, value}
    end
  end

  defp read_list(fun) do
    case PersistenceProvider.read(fun) do
      values when is_list(values) -> {:ok, values}
      {:error, :repo_unavailable} = error -> error
      {:error, {:query_failed, _reason}} = error -> error
      other -> {:error, {:query_failed, {:invalid_persistence_result, other}}}
    end
  end

  defp issue_payload(nil), do: nil

  defp issue_payload(issue) do
    %{
      id: value(issue, :id),
      tracker_issue_id: value(issue, :tracker_issue_id),
      identifier: value(issue, :identifier),
      title: value(issue, :title),
      state: value(issue, :state),
      url: value(issue, :url),
      project_id: value(issue, :project_id),
      updated_at: iso8601(value(issue, :updated_at))
    }
  end

  defp run_payload(run) do
    %{
      id: value(run, :id),
      kind: value(run, :kind),
      profile: value(run, :profile),
      status: value(run, :status),
      attempt: value(run, :attempt),
      started_at: iso8601(value(run, :started_at)),
      finished_at: iso8601(value(run, :finished_at)),
      failure_reason: value(run, :failure_reason)
    }
  end

  defp event_payload(event) do
    row = EventPresenter.row(event)

    %{
      id: row.id,
      run_id: row.run_id,
      event_type: row.event_type,
      occurred_at: iso8601(row.occurred_at),
      source: row.source,
      severity: row.severity,
      summary: row.summary,
      detail: row.detail
    }
  end

  defp newest_runs(runs), do: Enum.sort_by(runs, &datetime_sort_key(value(&1, :started_at)), :desc)
  defp newest_events(events), do: Enum.sort_by(events, &datetime_sort_key(value(&1, :occurred_at)), :desc)

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp datetime_sort_key(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp datetime_sort_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _invalid -> 0
    end
  end

  defp datetime_sort_key(_value), do: 0

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp iso8601(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil
end
