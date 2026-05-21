defmodule SymphonyElixir.RunHistory do
  @moduledoc """
  Presentation boundary for historical run session events.
  """

  alias SymphonyElixir.{Payload, StateName, StatusDashboard}

  @default_limit 100
  @max_payload_chars 800

  @spec list_run_session_events(module(), String.t(), keyword()) :: [map()]
  def list_run_session_events(persistence, run_id, opts \\ [])
      when is_atom(persistence) and is_binary(run_id) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    persistence.list_events(run_id: run_id, limit: limit, order: :asc)
    |> Enum.map(&from_event/1)
  end

  @spec from_events([term()]) :: [map()]
  def from_events(events) when is_list(events) do
    events
    |> Enum.sort_by(&event_time_sort_key/1)
    |> Enum.map(&from_event/1)
  end

  @spec from_event(term()) :: map()
  def from_event(event) do
    type = event_type(event)
    payload = event_payload(event)

    %{
      at: event_time(event),
      event: type,
      label: label(type, payload),
      detail: detail(type, payload),
      severity: severity(type, payload),
      source: source(type, payload),
      phase: payload_value(payload, ["phase", :phase]),
      operation: payload_value(payload, ["operation", :operation, "hook", :hook, "hook_name", :hook_name]),
      metadata: bounded_payload(payload)
    }
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(500)
  defp normalize_limit(_limit), do: @default_limit

  defp event_type(event), do: event |> value([:event_type, "event_type", :event, "event"]) |> to_string()
  defp event_payload(event), do: value(event, [:payload, "payload"]) || %{}
  defp event_time(event), do: value(event, [:occurred_at, "occurred_at", :at, "at"])

  defp event_time_sort_key(event) do
    case event_time(event) do
      %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp label("run.started", _payload), do: "Run started"
  defp label("run.completed", _payload), do: "Run completed"
  defp label("run.failed", _payload), do: "Run failed"
  defp label("run.stopped", _payload), do: "Run stopped"
  defp label("run.phase", payload), do: "Run phase #{payload_value(payload, ["status", :status]) || "updated"}"
  defp label("workspace.hook_output", payload), do: "Workspace #{payload_value(payload, ["hook", :hook, "hook_name", :hook_name]) || "hook"} output"
  defp label("workspace.hook_completed", payload), do: "Workspace #{payload_value(payload, ["hook", :hook, "hook_name", :hook_name]) || "hook"} completed"
  defp label("workspace.hook_failed", payload), do: "Workspace #{payload_value(payload, ["hook", :hook, "hook_name", :hook_name]) || "hook"} failed"
  defp label("linear.state_transition", _payload), do: "Linear state transition"

  defp label(type, payload) do
    payload_value(payload, ["label", :label]) ||
      type
      |> String.replace(".", " ")
      |> String.replace("_", " ")
      |> String.capitalize()
  end

  defp detail("run.phase", payload) do
    [payload_value(payload, ["phase", :phase]), payload_value(payload, ["status", :status])]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> fallback(payload_message(payload))
  end

  defp detail("linear.state_transition", payload) do
    from_state = payload_value(payload, ["from_state", :from_state])
    to_state = payload_value(payload, ["to_state", :to_state])

    if blank?(from_state) or blank?(to_state) do
      payload_message(payload)
    else
      "#{from_state} -> #{to_state}"
    end
  end

  defp detail(type, payload) do
    payload_value(payload, ["detail", :detail]) ||
      payload_value(payload, ["output", :output, "recent_output", :recent_output]) ||
      payload_message(payload) ||
      type
  end

  defp payload_message(payload) do
    case payload_value(payload, ["message", :message]) do
      nil -> nil
      message -> StatusDashboard.humanize_codex_message(message)
    end
  end

  defp fallback("", fallback), do: fallback || ""
  defp fallback(value, _fallback), do: value

  defp severity(type, payload) do
    cond do
      type in ["run.failed", "workspace.hook_failed"] -> :error
      type in ["run.stopped"] -> :warning
      payload_value(payload, ["status", :status]) in ["failed", "error"] -> :error
      payload_value(payload, ["severity", :severity]) in [:warning, "warning"] -> :warning
      payload_value(payload, ["severity", :severity]) in [:error, "error"] -> :error
      true -> :info
    end
  end

  defp source(type, payload) do
    payload_value(payload, ["source", :source]) ||
      cond do
        String.starts_with?(type, "linear.") -> :linear
        String.starts_with?(type, "workspace.") -> :system
        String.starts_with?(type, "run.") -> :system
        true -> :agent
      end
  end

  defp bounded_payload(payload) when is_map(payload) do
    payload
    |> Enum.map(fn {key, value} -> {key, bound_value(value)} end)
    |> Map.new()
  end

  defp bounded_payload(_payload), do: %{}

  defp bound_value(value) when is_binary(value) do
    if String.length(value) > @max_payload_chars, do: String.slice(value, 0, @max_payload_chars) <> "...", else: value
  end

  defp bound_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp bound_value(value) when is_map(value), do: bounded_payload(value)
  defp bound_value(value) when is_list(value), do: Enum.map(value, &bound_value/1)
  defp bound_value(value), do: value

  defp payload_value(payload, keys), do: Payload.get_any(payload, keys)

  defp value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp value(_map, _keys), do: nil

  defp blank?(value), do: StateName.blank_string?(value) or (not is_binary(value) and SymphonyElixir.Text.blankish?(value))
end
