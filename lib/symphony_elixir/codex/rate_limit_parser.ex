defmodule SymphonyElixir.Codex.RateLimitParser do
  @moduledoc """
  Normalizes known Codex rate-limit payload shapes.
  """

  alias SymphonyElixir.Payload

  @spec parse(term()) :: map() | nil
  def parse(payload) when is_map(payload) do
    limit_id = Payload.get_any(payload, ["limit_id", :limit_id, "limitId", :limitId])
    limit_name = Payload.get_any(payload, ["limit_name", :limit_name, "limitName", :limitName])

    if (present?(limit_id) or present?(limit_name)) and has_rate_limit_data?(payload) do
      payload
      |> put_present("limit_id", limit_id)
      |> put_present("limit_name", limit_name)
      |> put_present("plan_type", Payload.get_any(payload, ["plan_type", :plan_type, "planType", :planType]))
      |> put_present("rate_limit_reached_type", Payload.get_any(payload, ["rate_limit_reached_type", :rate_limit_reached_type, "rateLimitReachedType", :rateLimitReachedType]))
      |> put_bucket("primary")
      |> put_bucket("secondary")
      |> put_optional_existing("credits", Payload.get_any(payload, ["credits", :credits]))
      |> drop_camel_keys()
    end
  end

  def parse(_payload), do: nil

  defp has_rate_limit_data?(payload) do
    Enum.any?(
      [
        "primary",
        :primary,
        "secondary",
        :secondary,
        "credits",
        :credits
      ],
      &Map.has_key?(payload, &1)
    )
  end

  defp put_bucket(payload, key) do
    case Payload.get_any(payload, [key, bucket_atom_key(key)]) do
      bucket when is_map(bucket) -> Map.put(payload, key, normalize_bucket(bucket))
      _other -> payload
    end
  end

  defp normalize_bucket(bucket) do
    bucket
    |> put_present("used_percent", Payload.get_any(bucket, ["used_percent", :used_percent, "usedPercent", :usedPercent]))
    |> put_present("window_duration_mins", Payload.get_any(bucket, ["window_duration_mins", :window_duration_mins, "windowDurationMins", :windowDurationMins]))
    |> put_present("resets_at", Payload.get_any(bucket, ["resets_at", :resets_at, "resetsAt", :resetsAt]))
    |> drop_camel_keys()
  end

  defp put_optional_existing(payload, key, value) do
    if Map.has_key?(payload, key) or Map.has_key?(payload, known_atom_key(key)) do
      Map.put(payload, key, value)
    else
      payload
    end
  end

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp drop_camel_keys(payload) do
    Map.drop(payload, [
      :limitId,
      "limitId",
      :limitName,
      "limitName",
      :planType,
      "planType",
      :rateLimitReachedType,
      "rateLimitReachedType",
      :usedPercent,
      "usedPercent",
      :windowDurationMins,
      "windowDurationMins",
      :resetsAt,
      "resetsAt"
    ])
  end

  defp bucket_atom_key("primary"), do: :primary
  defp bucket_atom_key("secondary"), do: :secondary

  defp known_atom_key("credits"), do: :credits
end
