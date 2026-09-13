defmodule SymphonyElixir.Codex.ModelCatalog do
  @moduledoc """
  Code-owned Codex model catalog snapshot used by workflow validation and Settings selectors.

  Snapshot evidence:

  - `codex --version`: `codex-cli 0.150.1`
  - `codex app-server generate-json-schema --out tmp/codex-schema-sym-108-20260913`
    shows `TurnStartParams.model` as nullable string, `TurnStartParams.effort`
    as nullable `ReasoningEffort`, `ReasoningEffort` as a non-empty string,
    and `model/list` returning `ModelListResponse`.
  - An initialized `codex app-server` `model/list` request with
    `%{"includeHidden" => false, "limit" => 100}` returned the rows captured
    below on 2026-09-13.
  """

  @type effort :: %{
          required(:reasoning_effort) => String.t(),
          required(:description) => String.t()
        }

  @type model :: %{
          required(:id) => String.t(),
          required(:model) => String.t(),
          required(:display_name) => String.t(),
          required(:default_reasoning_effort) => String.t(),
          required(:supported_reasoning_efforts) => [effort()]
        }

  @type option :: {String.t(), String.t()}

  @snapshot %{
    codex_version: "codex-cli 0.150.1",
    generated_schema_command: "codex app-server generate-json-schema --out tmp/codex-schema-sym-108-20260913",
    model_list_request: %{"includeHidden" => false, "limit" => 100},
    captured_at: "2026-09-13"
  }

  @effort_descriptions %{
    "low" => "Fast responses with lighter reasoning",
    "medium" => "Balances speed and reasoning depth for everyday tasks",
    "high" => "Greater reasoning depth for complex problems",
    "xhigh" => "Extra high reasoning depth for complex problems",
    "max" => "Maximum reasoning depth for the hardest problems",
    "ultra" => "Maximum reasoning with automatic task delegation"
  }

  @models [
    %{
      id: "gpt-5.6-sol",
      model: "gpt-5.6-sol",
      display_name: "GPT-5.6-Sol",
      default_reasoning_effort: "low",
      supported_reasoning_efforts: ~w(low medium high xhigh max ultra)
    },
    %{
      id: "gpt-5.6-terra",
      model: "gpt-5.6-terra",
      display_name: "GPT-5.6-Terra",
      default_reasoning_effort: "medium",
      supported_reasoning_efforts: ~w(low medium high xhigh max ultra)
    },
    %{
      id: "gpt-5.6-luna",
      model: "gpt-5.6-luna",
      display_name: "GPT-5.6-Luna",
      default_reasoning_effort: "medium",
      supported_reasoning_efforts: ~w(low medium high xhigh max)
    },
    %{
      id: "gpt-5.5",
      model: "gpt-5.5",
      display_name: "GPT-5.5",
      default_reasoning_effort: "medium",
      supported_reasoning_efforts: ~w(low medium high xhigh)
    },
    %{
      id: "gpt-5.3-codex-spark",
      model: "gpt-5.3-codex-spark",
      display_name: "GPT-5.3-Codex-Spark",
      default_reasoning_effort: "high",
      supported_reasoning_efforts: ~w(low medium high xhigh)
    }
  ]

  @spec source_evidence() :: map()
  def source_evidence, do: @snapshot

  @spec models() :: [model()]
  def models do
    Enum.map(@models, &normalize_model/1)
  end

  @spec model_ids() :: [String.t()]
  def model_ids, do: Enum.map(@models, & &1.model)

  @spec reasoning_efforts() :: [String.t()]
  def reasoning_efforts do
    @models
    |> Enum.flat_map(& &1.supported_reasoning_efforts)
    |> Enum.uniq()
  end

  @spec reasoning_efforts_for_model(String.t()) :: [String.t()]
  def reasoning_efforts_for_model(model) when is_binary(model) do
    @models
    |> Enum.find_value([], fn row ->
      if row.model == model, do: row.supported_reasoning_efforts
    end)
  end

  @spec model?(String.t()) :: boolean()
  def model?(model) when is_binary(model), do: model in model_ids()

  @spec reasoning_effort?(String.t()) :: boolean()
  def reasoning_effort?(effort) when is_binary(effort), do: effort in reasoning_efforts()

  @spec supports_reasoning_effort?(String.t(), String.t()) :: boolean()
  def supports_reasoning_effort?(model, effort) when is_binary(model) and is_binary(effort) do
    effort in reasoning_efforts_for_model(model)
  end

  @spec model_options() :: [option()]
  def model_options do
    Enum.map(@models, &{model_label(&1), &1.model})
  end

  @spec reasoning_effort_options(String.t() | nil) :: [option()]
  def reasoning_effort_options(model) when is_binary(model) do
    efforts =
      case reasoning_efforts_for_model(model) do
        [] -> reasoning_efforts()
        model_efforts -> model_efforts
      end

    Enum.map(efforts, &{effort_label(&1), &1})
  end

  def reasoning_effort_options(nil), do: Enum.map(reasoning_efforts(), &{effort_label(&1), &1})

  @spec display_name(String.t()) :: String.t()
  def display_name(model) when is_binary(model) do
    @models
    |> Enum.find_value(model, fn row ->
      if row.model == model, do: row.display_name
    end)
  end

  defp normalize_model(row) do
    Map.update!(row, :supported_reasoning_efforts, fn efforts ->
      Enum.map(efforts, fn effort ->
        %{reasoning_effort: effort, description: Map.fetch!(@effort_descriptions, effort)}
      end)
    end)
  end

  defp model_label(row) do
    "#{row.display_name} (default #{row.default_reasoning_effort})"
  end

  defp effort_label(effort) do
    "#{effort} - #{Map.fetch!(@effort_descriptions, effort)}"
  end
end
