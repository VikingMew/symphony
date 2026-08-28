defmodule SymphonyElixirWeb.Admin.ObservabilityPresenter do
  @moduledoc """
  Presentation helpers for AdminLive observability pages.
  """

  alias SymphonyElixir.Redaction

  @spec fmt_dt(term()) :: String.t()
  def fmt_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def fmt_dt(_), do: "n/a"

  @spec fmt_duration(term(), term()) :: String.t()
  def fmt_duration(%DateTime{} = started_at, %DateTime{} = finished_at) do
    elapsed = DateTime.diff(finished_at, started_at, :second)

    cond do
      elapsed < 0 -> "n/a"
      elapsed < 60 -> "#{elapsed}s"
      elapsed < 3_600 -> "#{div(elapsed, 60)}m #{rem(elapsed, 60)}s"
      true -> "#{div(elapsed, 3_600)}h #{div(rem(elapsed, 3_600), 60)}m"
    end
  end

  def fmt_duration(_started_at, _finished_at), do: "running"

  @spec safe_event_payload(term()) :: String.t()
  def safe_event_payload(payload) do
    payload
    |> Redaction.payload(500)
    |> inspect(pretty: true, limit: 20)
    |> truncate(2_000)
  end

  @spec labels_text(term()) :: String.t()
  def labels_text(%{"values" => labels}) when is_list(labels), do: Enum.join(labels, ", ")
  def labels_text(_), do: ""

  @spec worker_empty_message(term()) :: String.t()
  def worker_empty_message(:centralized), do: "Worker-backed mode is inactive. Centralized execution does not require registered workers."
  def worker_empty_message("centralized"), do: worker_empty_message(:centralized)
  def worker_empty_message(_mode), do: "No workers are registered. Worker-backed execution expects compatible workers to register through the worker API."

  @spec status_class(term()) :: String.t()
  def status_class(status) when status in ["completed", "healthy", "online"], do: "status-badge status-success"
  def status_class(status) when status in ["info"], do: "status-badge status-info"
  def status_class(status) when status in ["queued", "pending", "waiting"], do: "status-badge status-accent"
  def status_class(status) when status in ["running", "retrying", "leased", "warning"], do: "status-badge status-warning"
  def status_class(status) when status in ["failed", "offline", "expired", "error"], do: "status-badge status-danger"
  def status_class(_), do: "status-badge"

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit do
    binary_part(value, 0, limit) <> "\n... truncated"
  end

  defp truncate(value, _limit), do: value
end
