defmodule SymphonyElixir.EventPresenter do
  @moduledoc """
  Normalized presentation rows for persisted events.
  """

  alias SymphonyElixir.Codex.MessageHumanizer
  alias SymphonyElixir.{Payload, Redaction, Text}

  @type row :: map()

  @spec rows([map()], keyword()) :: %{visible: [row()], hidden_low_signal_count: non_neg_integer()}
  def rows(events, opts \\ []) when is_list(events) do
    hide_low_signal? = Keyword.get(opts, :hide_low_signal?, true)
    severity = normalize_filter(Keyword.get(opts, :severity))
    source = normalize_filter(Keyword.get(opts, :source))

    presented = Enum.map(events, &row/1)

    filtered =
      presented
      |> filter_by(:severity, severity)
      |> filter_by(:source, source)

    hidden = Enum.count(filtered, & &1.low_signal?)
    visible = if hide_low_signal?, do: Enum.reject(filtered, & &1.low_signal?), else: filtered

    %{visible: visible, hidden_low_signal_count: if(hide_low_signal?, do: hidden, else: 0)}
  end

  @spec row(map()) :: row()
  def row(event) when is_map(event) do
    payload = Map.get(event, :payload) || Map.get(event, "payload") || %{}
    type = Map.get(event, :event_type) || Map.get(event, "event_type") || "unknown"

    base = %{
      id: Map.get(event, :id) || Map.get(event, "id"),
      occurred_at: Map.get(event, :occurred_at) || Map.get(event, "occurred_at"),
      issue_identifier: Map.get(event, :issue_identifier) || Map.get(event, "issue_identifier"),
      run_id: Map.get(event, :run_id) || Map.get(event, "run_id"),
      event_type: type,
      source: source(type, payload),
      severity: severity(type, payload),
      summary: summary(type, payload),
      detail: detail(type, payload),
      low_signal?: low_signal?(type, payload),
      raw_payload: scrub(payload)
    }

    Map.put(base, :category, category(base))
  end

  defp filter_by(rows, _key, nil), do: rows
  defp filter_by(rows, key, value), do: Enum.filter(rows, &(to_string(Map.get(&1, key)) == value))

  defp normalize_filter(value) when value in [nil, ""], do: nil
  defp normalize_filter(value), do: to_string(value)

  defp source(type, _payload) do
    cond do
      type in ["linear.state_transition"] -> :linear
      type in ["workspace.phase", "workspace.hook", "workspace.prepare"] -> :workspace
      type in ["worker.task", "worker.heartbeat"] -> :worker
      type == "codex.update" -> :agent
      is_binary(type) and (String.starts_with?(type, "run.") or String.starts_with?(type, "issue.")) -> :system
      true -> :unknown
    end
  end

  defp severity(type, payload) do
    cond do
      String.contains?(to_string(type), ["failed", "error"]) -> :error
      payload_status(payload) in ["failed", "error"] -> :error
      String.contains?(to_string(type), ["stopped", "cancelled", "expired"]) -> :warning
      payload_status(payload) in ["warning", "skipped"] -> :warning
      true -> :info
    end
  end

  defp summary("codex.update", payload) do
    message = Map.get(payload, :message) || Map.get(payload, "message")

    if empty_codex_notification?(payload) do
      "Empty Codex notification"
    else
      MessageHumanizer.humanize_codex_message(%{event: payload_event(payload), message: message})
    end
  end

  defp summary("linear.state_transition", payload) do
    from = payload_value(payload, ["from_state", "from"])
    to = payload_value(payload, ["to_state", "to"])
    "Linear state moved #{from || "n/a"} -> #{to || "n/a"}"
  end

  defp summary(type, payload) when is_binary(type) and type in ["run.failed", "run.completed", "run.started"] do
    reason = payload_value(payload, ["failure_reason", "reason", "message"])
    if Text.blankish?(reason), do: type, else: "#{type}: #{reason}"
  end

  defp summary(type, payload) do
    payload_value(payload, ["message", "summary", "reason"]) || type
  end

  defp detail("codex.update", payload) do
    if empty_codex_notification?(payload), do: "Empty Codex notification; detailed payload was not persisted.", else: nil
  end

  defp detail(type, payload) do
    payload_value(payload, ["detail", "output", "recent_output", "phase"]) || type
  end

  defp low_signal?("codex.update", payload), do: empty_codex_notification?(payload)
  defp low_signal?(_type, _payload), do: false

  defp empty_codex_notification?(payload) do
    payload_event(payload) in [:notification, "notification"] and
      blank_payload_text?(Map.get(payload, :message) || Map.get(payload, "message")) and
      blank_payload_text?(Map.get(payload, :raw) || Map.get(payload, "raw"))
  end

  defp blank_payload_text?(nil), do: true
  defp blank_payload_text?(value) when is_binary(value), do: Text.blankish?(value)
  defp blank_payload_text?(_value), do: false

  defp payload_event(payload), do: Map.get(payload, :event) || Map.get(payload, "event")
  defp payload_status(payload), do: to_string(payload_value(payload, ["status"]) || "")

  defp payload_value(payload, keys) do
    Enum.find_value(keys, fn key -> Payload.get_any(payload, [key, known_atom_key(key)]) end)
  end

  defp known_atom_key("detail"), do: :detail
  defp known_atom_key("failure_reason"), do: :failure_reason
  defp known_atom_key("from"), do: :from
  defp known_atom_key("from_state"), do: :from_state
  defp known_atom_key("message"), do: :message
  defp known_atom_key("output"), do: :output
  defp known_atom_key("phase"), do: :phase
  defp known_atom_key("reason"), do: :reason
  defp known_atom_key("recent_output"), do: :recent_output
  defp known_atom_key("status"), do: :status
  defp known_atom_key("summary"), do: :summary
  defp known_atom_key("to"), do: :to
  defp known_atom_key("to_state"), do: :to_state
  defp known_atom_key(_key), do: nil

  defp category(%{source: :workspace}), do: :workspace
  defp category(%{source: :linear}), do: :linear

  defp category(%{event_type: type}) when is_binary(type) do
    cond do
      String.starts_with?(type, "run.") -> :run_lifecycle
      type == "codex.update" -> :codex
      true -> :audit
    end
  end

  defp category(_row), do: :audit

  defp scrub(%{} = payload) do
    Map.new(payload, fn {key, value} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, scrub(value)}
    end)
  end

  defp scrub(value) when is_binary(value), do: Redaction.credentials(value)
  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  defp scrub(value), do: value

  defp sensitive_key?(key), do: key |> to_string() |> String.downcase() |> String.contains?(["token", "secret", "authorization", "api_key", "cookie"])
end
