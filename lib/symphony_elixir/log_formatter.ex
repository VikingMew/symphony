defmodule SymphonyElixir.LogFormatter do
  @moduledoc """
  Formats first-party Logger events as one JSON object per line.
  """

  @metadata_fields [
    :issue_id,
    :issue_identifier,
    :run_id,
    :session_id,
    :thread_id,
    :turn_id,
    :tool_call_id,
    :operation,
    :location,
    :offending_value,
    :expected_shape,
    :error_code,
    :retryable,
    :duration_ms,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :token_budget,
    :budget_remaining
  ]

  @spec format(map(), map()) :: IO.chardata()
  def format(%{level: level, msg: _message, meta: metadata} = event, _config)
      when is_map(metadata) do
    record =
      %{
        timestamp: timestamp(metadata),
        level: Atom.to_string(level),
        event: event_name(metadata),
        message: message(event),
        source: source(metadata)
      }
      |> put_metadata(metadata)

    [Jason.encode!(record), ?\n]
  end

  defp timestamp(metadata) do
    metadata
    |> Map.get(:time, System.system_time(:microsecond))
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp event_name(metadata) do
    case Map.get(metadata, :event) do
      event when is_binary(event) and event != "" -> event
      nil -> "application.log"
      event when is_atom(event) -> Atom.to_string(event)
      _ -> "application.log"
    end
  end

  defp message(event) do
    event
    |> :logger_formatter.format(%{template: [:msg], single_line: true})
    |> :unicode.characters_to_binary()
    |> String.trim_trailing()
  end

  defp source(metadata) do
    %{}
    |> put_present(:module, metadata |> Map.get(:mfa) |> mfa_module())
    |> put_present(:function, metadata |> Map.get(:mfa) |> mfa_function())
    |> put_present(:file, metadata |> Map.get(:file) |> normalize_file())
    |> put_present(:line, Map.get(metadata, :line))
  end

  defp put_metadata(record, metadata) do
    Enum.reduce(@metadata_fields, record, fn key, acc ->
      put_present(acc, key, metadata |> Map.get(key) |> normalize_value())
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp mfa_module({module, _function, _arity}), do: inspect(module)
  defp mfa_module(_mfa), do: nil

  defp mfa_function({_module, function, arity}), do: "#{function}/#{arity}"
  defp mfa_function(_mfa), do: nil

  defp normalize_file(file) when is_list(file), do: List.to_string(file)
  defp normalize_file(file) when is_binary(file), do: file
  defp normalize_file(_file), do: nil

  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_tuple(value), do: inspect(value)
  defp normalize_value(value), do: value
end
