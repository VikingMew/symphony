defmodule SymphonyElixir.WorkerResult do
  @moduledoc """
  Validates the bounded execution evidence accepted from worker-api-v1.
  """

  @max_gates 32
  @max_text 512
  @max_detail 2_048
  @phases ~w(checkout codex hooks validation handoff complete)
  @outcomes ~w(running succeeded failed cancelled)
  @reasons ~w(in_progress completed non_zero timed_out cancelled lease_lost worker_error handoff_failed)
  @validation_statuses ~w(pending passed failed timed_out cancelled)
  @gate_statuses ~w(passed failed timed_out not_run)
  @path_pattern ~r{(?:^|\s)(?:/[^\s]+|[A-Za-z]:\\[^\s]+)}
  @secret_pattern ~r/(?i)(?:api[_-]?key|authorization|bearer|password|secret|token)\s*[:=]\s*\S+/

  @spec validate(term()) :: {:ok, map()} | {:error, {:invalid_worker_summary, String.t()}}
  def validate(summary) when is_map(summary) do
    summary = stringify_keys(summary)

    with :ok <- enum(summary, "phase", @phases),
         :ok <- enum(summary, "outcome", @outcomes),
         :ok <- enum(summary, "reason", @reasons),
         :ok <- timestamp(summary, "occurred_at", true),
         :ok <- timestamp(summary, "started_at", false),
         :ok <- timestamp(summary, "finished_at", false),
         :ok <- non_negative_integer(summary, "duration_ms", false),
         :ok <- bounded_text(summary, "session_id", @max_text, false),
         :ok <- bounded_text(summary, "source_revision", @max_text, true),
         :ok <- runtime(summary["runtime"]),
         :ok <- enum(summary, "validation_status", @validation_statuses),
         :ok <- gates(summary["gates"]),
         :ok <- handoff(summary["handoff"]) do
      {:ok, summary}
    end
  end

  def validate(_), do: invalid("summary must be an object")

  @spec limits() :: map()
  def limits, do: %{max_gates: @max_gates, max_text: @max_text, max_detail: @max_detail}

  defp runtime(value) when is_map(value) do
    value = stringify_keys(value)
    digest = value["image_digest"]
    tag = value["image_tag"]

    with :ok <- require_runtime_image(digest, tag),
         :ok <- bounded_text(value, "image_digest", @max_text, false),
<<<<<<< HEAD
         :ok <- bounded_text(value, "image_tag", @max_text, false) do
      bounded_text(value, "worker_source_revision", @max_text, true)
    end
=======
         :ok <- bounded_text(value, "image_tag", @max_text, false),
         do: bounded_text(value, "worker_source_revision", @max_text, true)
>>>>>>> origin/main
  end

  defp runtime(_), do: invalid("runtime must be an object")

  defp require_runtime_image(digest, tag) do
    if present?(digest) or present?(tag), do: :ok, else: invalid("runtime requires image_digest or image_tag")
  end

  defp gates(values) when is_list(values) and length(values) <= @max_gates do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {gate, index}, :ok ->
      case gate(gate) do
        :ok -> {:cont, :ok}
        {:error, {:invalid_worker_summary, message}} -> {:halt, invalid("gate #{index}: #{message}")}
      end
    end)
  end

  defp gates(values) when is_list(values), do: invalid("gate count exceeds #{@max_gates}")
  defp gates(_), do: invalid("gates must be a list")

  defp gate(value) when is_map(value) do
    value = stringify_keys(value)

    with :ok <- bounded_text(value, "name", @max_text, true),
         :ok <- enum(value, "status", @gate_statuses),
         :ok <- exit_code(value),
         :ok <- non_negative_integer(value, "duration_ms", true),
<<<<<<< HEAD
         :ok <- positive_integer(value, "timeout_ms") do
      bounded_detail(value, "failure_detail")
    end
=======
         :ok <- positive_integer(value, "timeout_ms"),
         do: bounded_detail(value, "failure_detail")
>>>>>>> origin/main
  end

  defp gate(_), do: invalid("must be an object")

  defp handoff(nil), do: :ok

  defp handoff(value) when is_map(value) do
    value = stringify_keys(value)

<<<<<<< HEAD
    with :ok <- bounded_detail(value, "error_detail") do
      validate_handoff_fields(value)
    end
=======
    with :ok <- bounded_detail(value, "error_detail"), do: handoff_fields(value)
>>>>>>> origin/main
  end

  defp handoff(_), do: invalid("handoff must be an object")

<<<<<<< HEAD
  defp validate_handoff_fields(value) do
    Enum.reduce_while(
      ~w(branch commit pr_identifier pr_url linear_issue linear_state failed_step),
      :ok,
      &validate_handoff_field(value, &1, &2)
    )
  end

  defp validate_handoff_field(value, key, :ok) do
    case bounded_text(value, key, @max_text, false) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

=======
  defp handoff_fields(value) do
    Enum.reduce_while(
      ~w(branch commit pr_identifier pr_url linear_issue linear_state failed_step),
      :ok,
      fn key, :ok ->
        case bounded_text(value, key, @max_text, false) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

>>>>>>> origin/main
  defp exit_code(%{"exit_code" => value}) when is_integer(value), do: :ok
  defp exit_code(%{"exit_code" => nil}), do: :ok
  defp exit_code(%{"status" => "failed"}), do: invalid("failed gate requires integer exit_code")
  defp exit_code(_), do: :ok

  defp bounded_detail(map, key) do
    case Map.get(map, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        cond do
          String.length(value) > @max_detail -> invalid("#{key} exceeds #{@max_detail} characters")
          Regex.match?(@path_pattern, value) -> invalid("#{key} contains a worker-local filesystem path")
          Regex.match?(@secret_pattern, value) -> invalid("#{key} contains secret-bearing text")
          true -> :ok
        end

      _ ->
        invalid("#{key} must be a string")
    end
  end

  defp bounded_text(map, key, limit, required) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" ->
        if String.length(value) <= limit, do: :ok, else: invalid("#{key} exceeds #{limit} characters")

      nil when not required ->
        :ok

      _ ->
        invalid("#{key} must be a non-empty string")
    end
  end

  defp enum(map, key, allowed) do
    if Map.get(map, key) in allowed, do: :ok, else: invalid("#{key} is invalid")
  end

  defp timestamp(map, key, required) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _, _} -> :ok
          _ -> invalid("#{key} must be an ISO-8601 timestamp")
        end

      nil when not required ->
        :ok

      _ ->
        invalid("#{key} must be an ISO-8601 timestamp")
    end
  end

  defp positive_integer(map, key) do
    if is_integer(map[key]) and map[key] > 0, do: :ok, else: invalid("#{key} must be a positive integer")
  end

  defp non_negative_integer(map, key, required) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> :ok
      nil when not required -> :ok
      _ -> invalid("#{key} must be a non-negative integer")
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
  defp invalid(message), do: {:error, {:invalid_worker_summary, message}}
end
