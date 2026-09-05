defmodule SymphonyElixir.Codex.RefinementDescriptionMeasurement do
  @moduledoc false

  @default_limits %{"characters" => 12_000, "lines" => 400, "label_overrides" => %{}}

  @type measurement :: %{
          characters: non_neg_integer(),
          lines: non_neg_integer(),
          character_limit: pos_integer(),
          line_limit: pos_integer(),
          over_limit: boolean(),
          label_overrides: [map()]
        }

  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  @spec measure(String.t(), [String.t()], map()) :: measurement()
  def measure(description, labels, configured_limits)
      when is_binary(description) and is_list(labels) and is_map(configured_limits) do
    limits = Map.merge(@default_limits, configured_limits)
    base = {limits["characters"], limits["lines"]}
    normalized_labels = MapSet.new(labels, &normalize_label/1)

    matches =
      limits
      |> Map.get("label_overrides", %{})
      |> Enum.filter(fn {label, _limits} -> MapSet.member?(normalized_labels, normalize_label(label)) end)
      |> Enum.map(fn {label, override} ->
        %{
          label: normalize_label(label),
          characters: Map.get(override, "characters", elem(base, 0)),
          lines: Map.get(override, "lines", elem(base, 1))
        }
      end)
      |> Enum.sort_by(& &1.label)

    character_limit = Enum.reduce(matches, elem(base, 0), &max(&1.characters, &2))
    line_limit = Enum.reduce(matches, elem(base, 1), &max(&1.lines, &2))
    characters = String.length(description)
    lines = logical_line_count(description)

    %{
      characters: characters,
      lines: lines,
      character_limit: character_limit,
      line_limit: line_limit,
      over_limit: characters > character_limit or lines > line_limit,
      label_overrides: matches
    }
  end

  @spec advisory(measurement()) :: String.t()
  def advisory(measurement) do
    "Description size: #{measurement.characters} characters / #{measurement.lines} lines " <>
      "(limits: #{measurement.character_limit} / #{measurement.line_limit}). " <>
      "Consider trimming it for clarity; this advisory does not block refinement."
  end

  defp logical_line_count(""), do: 0

  defp logical_line_count(description) do
    description
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> length()
  end

  defp normalize_label(label), do: label |> to_string() |> String.trim() |> String.downcase()
end
