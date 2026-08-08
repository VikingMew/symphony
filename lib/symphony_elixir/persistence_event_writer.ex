defmodule SymphonyElixir.PersistenceEventWriter do
  @moduledoc """
  Writes one runtime event while preserving persistence failures for the caller.
  """

  require Logger

  alias SymphonyElixir.PersistenceProvider

  @type result :: :ok | {:degraded, term()} | {:error, term()}

  @spec record(map()) :: result()
  def record(attrs) when is_map(attrs), do: record(attrs, %{})

  @spec record(map(), map()) :: result()
  def record(attrs, context) when is_map(attrs) and is_map(context) do
    result =
      try do
        PersistenceProvider.module().record_event(attrs)
      rescue
        error -> {:raised, error, __STACKTRACE__}
      end

    handle_result(result, attrs, persistence_context(attrs, context))
  end

  defp handle_result({:ok, _event}, _attrs, _context), do: :ok

  defp handle_result({:error, :repo_unavailable}, attrs, context) do
    result = {:degraded, :repo_unavailable}
    log_degraded(attrs, context, result)
    result
  end

  defp handle_result({:error, reason}, attrs, context) do
    result = {:error, reason}
    log_failure(attrs, context, result)
    result
  end

  defp handle_result({:raised, error, stacktrace}, attrs, context) do
    result = {:error, {:exception, error, stacktrace}}
    log_failure(attrs, context, {:error, {:exception, error}})
    result
  end

  defp handle_result(other, attrs, context) do
    result = {:error, {:unexpected_result, other}}
    log_failure(attrs, context, result)
    result
  end

  defp log_degraded(attrs, context, result) do
    Logger.warning(
      "Persistence event write degraded operation=record_event action=return_degraded event_type=#{log_field(Map.get(attrs, :event_type))} #{log_context(context)} outcome=#{inspect(result, limit: 20, printable_limit: 1_000)}"
    )
  end

  defp log_failure(attrs, context, result) do
    Logger.error(
      "Persistence event write failed operation=record_event action=return_error event_type=#{log_field(Map.get(attrs, :event_type))} #{log_context(context)} outcome=#{inspect(result, limit: 20, printable_limit: 1_000)}"
    )
  end

  defp persistence_context(attrs, explicit_context) do
    payload = Map.get(attrs, :payload, %{})

    %{
      issue_id: value(explicit_context, payload, :issue_id),
      issue_identifier: Map.get(explicit_context, :issue_identifier) || Map.get(attrs, :issue_identifier),
      session_id: value(explicit_context, payload, :session_id),
      run_id: Map.get(explicit_context, :run_id) || Map.get(attrs, :run_id) || payload_value(payload, :run_id)
    }
  end

  defp value(explicit_context, payload, key) do
    Map.get(explicit_context, key) || payload_value(payload, key)
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_payload, _key), do: nil

  defp log_context(context) do
    "issue_id=#{log_field(Map.get(context, :issue_id))} issue_identifier=#{log_field(Map.get(context, :issue_identifier))} session_id=#{log_field(Map.get(context, :session_id))} run_id=#{log_field(Map.get(context, :run_id))}"
  end

  defp log_field(nil), do: "n/a"
  defp log_field(value), do: inspect(value, limit: 5, printable_limit: 200)
end
