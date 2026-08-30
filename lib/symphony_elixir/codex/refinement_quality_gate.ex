defmodule SymphonyElixir.Codex.RefinementQualityGate do
  @required ["Goal", "Scope", "Out of scope", "Acceptance criteria", "Validation"]
  @markers ~r/\[NEEDS CLARIFICATION\]|\[TODO\]|TODO:|TBD|\?\?\?/i

  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(description) when is_binary(description) do
    sections = sections(description)
    missing = Enum.flat_map(@required, fn name -> if blank?(Map.get(sections, norm(name))), do: ["missing_required_section: #{name}"], else: [] end)
    missing = if Regex.match?(@markers, description), do: missing ++ ["ambiguous_marker"], else: missing
    missing = if Regex.match?(~r/\[CONTEXT REQUIRED\]/i, description), do: missing ++ ["implicit_context_reference"], else: missing
    missing = if unresolved?(sections), do: missing ++ ["unresolved_questions"], else: missing
    missing = if acceptance_missing?(sections), do: missing ++ ["missing_testable_acceptance"], else: missing

    case Enum.uniq(missing) do
      [] -> :ok
      items -> {:error, items}
    end
  end

  def validate(_), do: {:error, ["missing_required_section: description"]}

  defp norm(v), do: v |> String.downcase() |> String.trim()
  defp blank?(nil), do: true
  defp blank?(v), do: String.trim(v) == ""

  defp sections(text) do
    Regex.scan(~r/^#+\s+(.+)\s*\n(.*?)(?=^#+\s+|\z)/ms, text)
    |> Map.new(fn [_, h, body] -> {norm(h), body} end)
  end

  defp unresolved?(sections) do
    Enum.any?(["open questions", "unresolved questions", "未决问题"], fn key ->
      case Map.get(sections, key) do
        nil -> false
        body -> String.trim(body) not in ["", "None", "无"]
      end
    end)
  end

  defp acceptance_missing?(sections) do
    body = Map.get(sections, "acceptance criteria", "")
    items = Regex.scan(~r/^\s*[-*+]\s+(.+)$/m, body, capture: :all_but_first)
    items == [] or Enum.all?(items, fn [item] -> Regex.match?(@markers, item) end)
  end
end
