defmodule SymphonyElixir.Orchestrator.SessionHistory do
  @moduledoc """
  Builds orchestrator-owned session history events.

  Codex update integration stays in `SymphonyElixir.Codex.Update`; this module
  owns lifecycle/system events emitted by the orchestrator and workspace.
  """

  alias SymphonyElixir.Codex.{MessageHumanizer, Update}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.RetryPolicy

  @default_history_limit 100

  @spec integrate_codex_update(map(), map(), keyword()) :: {map(), map()}
  def integrate_codex_update(running_entry, %{event: _event, timestamp: _timestamp} = update, opts \\ []) do
    Update.integrate(running_entry, update, history_limit: history_limit(opts))
  end

  @spec initial(Issue.t(), term(), String.t() | nil, keyword()) :: [map()]
  def initial(%Issue{} = issue, attempt, worker_host, opts \\ []) do
    [
      event(
        :run_started,
        "Run started",
        %{
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          state: issue.state,
          attempt: RetryPolicy.normalize_attempt(attempt),
          worker_host: worker_host
        },
        opts
      )
    ]
  end

  @spec append(map(), atom(), String.t(), map(), keyword()) :: map()
  def append(running_entry, event, label, metadata, opts \\ []) when is_map(running_entry) do
    history = Map.get(running_entry, :session_history, [])
    next = event(event, label, metadata, opts)

    running_entry
    |> Map.put(:session_history, Enum.take(history ++ [next], -history_limit(opts)))
    |> Map.put(:session_history_total_count, Map.get(running_entry, :session_history_total_count, length(history)) + 1)
  end

  @spec append_system(map(), map(), keyword()) :: map()
  def append_system(running_entry, update, opts \\ []) when is_map(running_entry) and is_map(update) do
    metadata =
      update
      |> Map.put_new(:source, :system)
      |> Map.put_new(:severity, system_update_severity(update))

    append_coalescible(
      running_entry,
      :system_progress,
      system_label(update),
      metadata,
      system_key(metadata),
      opts
    )
  end

  @spec event(atom(), String.t(), map(), keyword()) :: map()
  def event(event, label, metadata, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      at: now,
      event: event,
      label: label,
      detail: detail(event, metadata),
      severity: severity(event, metadata),
      source: source(event, metadata),
      metadata: sanitize_metadata(metadata)
    }
  end

  defp append_coalescible(running_entry, event, label, metadata, coalescing_key, opts) when is_map(running_entry) do
    metadata = Map.put(metadata, :coalescing_key, coalescing_key)
    history = Map.get(running_entry, :session_history, [])
    total_count = Map.get(running_entry, :session_history_total_count, length(history)) + 1
    next = event(event, label, metadata, opts)

    case history do
      [] ->
        running_entry
        |> Map.put(:session_history, [next])
        |> Map.put(:session_history_total_count, total_count)

      _ ->
        {last, rest_reversed} = pop_last(history)

        if coalescible?(last, event, coalescing_key) do
          updated_last =
            next
            |> Map.put(:at, Map.get(last, :at))
            |> Map.put(:metadata, merge_coalesced_metadata(Map.get(last, :metadata, %{}), Map.get(next, :metadata, %{}), opts))

          running_entry
          |> Map.put(:session_history, Enum.take(Enum.reverse(rest_reversed) ++ [updated_last], -history_limit(opts)))
          |> Map.put(:session_history_total_count, total_count)
        else
          running_entry
          |> Map.put(:session_history, Enum.take(history ++ [next], -history_limit(opts)))
          |> Map.put(:session_history_total_count, total_count)
        end
    end
  end

  defp history_limit(opts), do: Keyword.get(opts, :history_limit, @default_history_limit)

  defp pop_last(history) do
    [last | rest_reversed] = Enum.reverse(history)
    {last, rest_reversed}
  end

  defp coalescible?(%{event: event, metadata: metadata}, event, coalescing_key) when is_map(metadata) do
    Map.get(metadata, :coalescing_key) == coalescing_key
  end

  defp coalescible?(_last, _event, _coalescing_key), do: false

  defp merge_coalesced_metadata(existing, next, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    existing
    |> Map.merge(next)
    |> Map.put(:coalesced_event_count, Map.get(existing, :coalesced_event_count, 1) + 1)
    |> Map.put(:coalesced_last_at, now)
  end

  defp system_update_severity(%{status: status}) when status in [:failed, "failed"], do: :error
  defp system_update_severity(%{status: status}) when status in [:warning, "warning"], do: :warning
  defp system_update_severity(_update), do: :info

  defp system_label(%{operation: operation}) when is_binary(operation) do
    operation
    |> String.replace("hook:", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp system_label(%{phase: phase}) when is_binary(phase) do
    phase
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp system_label(_update), do: "System"

  defp system_key(metadata) do
    [
      Map.get(metadata, :source),
      Map.get(metadata, :phase),
      Map.get(metadata, :operation)
    ]
  end

  defp detail(:workspace_ready, %{workspace_path: path}) when is_binary(path), do: path
  defp detail(:run_started, %{state: state}) when is_binary(state), do: "Started from #{state}"
  defp detail(:linear_state_transition, %{from_state: from_state, to_state: to_state}) when is_binary(from_state) and is_binary(to_state), do: "#{from_state} -> #{to_state}"
  defp detail(:system_progress, %{detail: detail}) when is_binary(detail), do: detail
  defp detail(_event, %{message: message}), do: MessageHumanizer.humanize_codex_message(message)
  defp detail(event, _metadata), do: to_string(event)

  defp source(_event, %{source: source}) when is_atom(source), do: source
  defp source(_event, %{source: source}) when is_binary(source), do: source
  defp source(:linear_state_transition, _metadata), do: :linear
  defp source(:system_progress, _metadata), do: :system
  defp source(:run_started, _metadata), do: :system
  defp source(:workspace_ready, _metadata), do: :system
  defp source(_event, _metadata), do: :agent

  defp severity(:system_progress, %{severity: severity}) when severity in [:info, :warning, :error], do: severity
  defp severity(event, _metadata) when event in [:startup_failed, :turn_ended_with_error, :turn_failed], do: :error
  defp severity(event, _metadata) when event in [:approval_required, :turn_input_required], do: :warning
  defp severity(_event, _metadata), do: :info

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {key, sanitize_value(value)} end)
    |> Map.new()
  end

  defp sanitize_value(value) when is_binary(value) do
    if String.length(value) > 500, do: String.slice(value, 0, 500) <> "...", else: value
  end

  defp sanitize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize_value(value) when is_map(value), do: sanitize_metadata(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)
  defp sanitize_value(value), do: value
end
