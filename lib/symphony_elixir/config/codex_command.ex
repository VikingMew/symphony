defmodule SymphonyElixir.Config.CodexCommand do
  @moduledoc false

  @type selector :: :model | :reasoning_effort

  @safe_token ~r|\A[A-Za-z0-9_@%+=:,./-]+\z|

  @spec override_fields(String.t()) :: [selector()]
  def override_fields(command) when is_binary(command) do
    command
    |> scan()
    |> Map.fetch!(:overrides)
    |> Map.keys()
    |> Enum.sort_by(&selector_order/1)
  end

  @spec validation_message([selector()]) :: String.t()
  def validation_message([:model]) do
    "must not set model; use the Settings / Runtime Codex model selector"
  end

  def validation_message([:reasoning_effort]) do
    "must not set model_reasoning_effort; use the Settings / Runtime reasoning effort selector"
  end

  def validation_message([:model, :reasoning_effort]) do
    "must not set model or model_reasoning_effort; use the Settings / Runtime Codex model and reasoning effort selectors"
  end

  @spec migrate_config(map()) :: :unchanged | {:changed, map()}
  def migrate_config(config) when is_map(config) do
    codex = Map.get(config, "codex", %{})
    command = Map.get(codex, "command", "codex app-server")
    %{kept: kept, overrides: overrides} = scan(command)

    if map_size(overrides) == 0 or Enum.any?(overrides, fn {_field, value} -> is_nil(value) end) do
      :unchanged
    else
      migrated_codex =
        codex
        |> put_missing_selector("model", Map.get(overrides, :model))
        |> put_missing_selector("reasoning_effort", Map.get(overrides, :reasoning_effort))
        |> Map.put("command", join_tokens(kept))

      {:changed, Map.put(config, "codex", migrated_codex)}
    end
  end

  @spec migrate_instance(map()) :: :unchanged | {:changed, map()}
  def migrate_instance(%{"config" => config} = instance) do
    case migrate_config(config) do
      {:changed, migrated} -> {:changed, Map.put(instance, "config", migrated)}
      :unchanged -> :unchanged
    end
  end

  @spec migrate_conflict(map()) :: :unchanged | {:changed, map()}
  def migrate_conflict(%{"candidates" => candidates} = conflict) do
    {migrated_candidates, changed?} =
      Enum.map_reduce(candidates, false, fn candidate, changed? ->
        case migrate_instance(Map.fetch!(candidate, "candidate")) do
          {:changed, migrated} -> {Map.put(candidate, "candidate", migrated), true}
          :unchanged -> {candidate, changed?}
        end
      end)

    if changed?,
      do: {:changed, Map.put(conflict, "candidates", migrated_candidates)},
      else: :unchanged
  end

  defp scan(command) do
    command
    |> OptionParser.split()
    |> scan_tokens(%{}, [])
  rescue
    RuntimeError -> %{overrides: %{}, kept: [command]}
  end

  defp scan_tokens([], overrides, kept) do
    %{overrides: overrides, kept: Enum.reverse(kept)}
  end

  defp scan_tokens([flag, value | rest], overrides, kept) when flag in ["-c", "--config"] do
    case config_selector(value) do
      {field, selector_value} -> scan_tokens(rest, Map.put(overrides, field, selector_value), kept)
      nil -> scan_tokens(rest, overrides, [value, flag | kept])
    end
  end

  defp scan_tokens([flag | rest], overrides, kept) when flag in ["-c", "--config"] do
    scan_tokens(rest, overrides, [flag | kept])
  end

  defp scan_tokens([flag, value | rest], overrides, kept) when flag in ["-m", "--model"] do
    scan_tokens(rest, Map.put(overrides, :model, selector_value(value)), kept)
  end

  defp scan_tokens([flag | rest], overrides, kept) when flag in ["-m", "--model"] do
    scan_tokens(rest, Map.put(overrides, :model, nil), kept)
  end

  defp scan_tokens([token | rest], overrides, kept) do
    case inline_override(token) do
      {field, value} -> scan_tokens(rest, Map.put(overrides, field, value), kept)
      nil -> scan_tokens(rest, overrides, [token | kept])
    end
  end

  defp inline_override("--config=" <> assignment), do: config_selector(assignment)
  defp inline_override("-c=" <> assignment), do: config_selector(assignment)
  defp inline_override("-c" <> assignment) when assignment != "", do: config_selector(assignment)
  defp inline_override("--model=" <> value), do: {:model, selector_value(value)}
  defp inline_override("-m=" <> value), do: {:model, selector_value(value)}
  defp inline_override("-m" <> value) when value != "", do: {:model, selector_value(value)}
  defp inline_override(_token), do: nil

  defp config_selector(assignment) do
    case String.split(assignment, "=", parts: 2) do
      ["model", value] -> {:model, selector_value(value)}
      ["model_reasoning_effort", value] -> {:reasoning_effort, selector_value(value)}
      _other -> nil
    end
  end

  defp selector_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp put_missing_selector(codex, _key, nil), do: codex

  defp put_missing_selector(codex, key, value) do
    case Map.get(codex, key) do
      current when is_binary(current) ->
        if String.trim(current) == "", do: Map.put(codex, key, value), else: codex

      nil ->
        Map.put(codex, key, value)

      _invalid ->
        codex
    end
  end

  defp join_tokens(tokens), do: Enum.map_join(tokens, " ", &quote_token/1)

  defp quote_token(token) do
    if Regex.match?(@safe_token, token) do
      token
    else
      "'" <> String.replace(token, "'", "'\"'\"'") <> "'"
    end
  end

  defp selector_order(:model), do: 0
  defp selector_order(:reasoning_effort), do: 1
end
