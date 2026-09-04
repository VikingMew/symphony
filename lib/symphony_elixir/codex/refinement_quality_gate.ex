defmodule SymphonyElixir.Codex.RefinementQualityGate do
  @moduledoc false

  @required_sections [
    {"goal", "Goal"},
    {"scope", "Scope"},
    {"out of scope", "Out of scope"},
    {"acceptance criteria", "Acceptance criteria"},
    {"validation", "Validation"}
  ]
  @ambiguous_marker ~r/\[NEEDS CLARIFICATION\]|\[TODO\]|TODO:|TBD|\?\?\?/i
  @context_marker ~r/\[CONTEXT REQUIRED\]/i
  @list_item ~r/^\s*(?:[-*+]\s+|\d+[.)]\s+)(.+)$/
  @question_sections ["open questions", "unresolved questions", "未决问题"]

  @type violation :: %{code: String.t(), message: String.t()}

  @spec validate(term()) :: :ok | {:error, [violation()]}
  def validate(description) when is_binary(description) do
    if String.trim(description) == "" do
      missing_description()
    else
      validate_description(description)
    end
  end

  def validate(_description), do: missing_description()

  defp validate_description(description) do
    sections = sections(description)

    violations =
      required_section_violations(sections) ++
        marker_violations(description) ++
        unresolved_question_violations(sections) ++ acceptance_violations(sections)

    case Enum.uniq(violations) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp missing_description do
    {:error, [violation("missing_required_section", "Provide a non-empty candidate description.")]}
  end

  defp required_section_violations(sections) do
    Enum.flat_map(@required_sections, fn {key, title} ->
      if blank?(Map.get(sections, key)) do
        [violation("missing_required_section", "Add a non-empty `#{title}` section.")]
      else
        []
      end
    end)
  end

  defp marker_violations(description) do
    []
    |> maybe_add(
      Regex.match?(@ambiguous_marker, description),
      violation("ambiguous_marker", "Remove explicit TODO, TBD, clarification, or `???` markers.")
    )
    |> maybe_add(
      Regex.match?(@context_marker, description),
      violation(
        "implicit_context_reference",
        "Replace `[CONTEXT REQUIRED]` with the required context."
      )
    )
  end

  defp unresolved_question_violations(sections) do
    if Enum.any?(@question_sections, &unresolved_questions?(Map.get(sections, &1))) do
      [
        violation(
          "unresolved_questions",
          "Resolve every open question or set the section to `None` or `无`."
        )
      ]
    else
      []
    end
  end

  defp acceptance_violations(sections) do
    sections
    |> Map.get("acceptance criteria", "")
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(@list_item, line, capture: :all_but_first) do
        [item] -> [String.trim(item)]
        nil -> []
      end
    end)
    |> Enum.any?(&testable_acceptance_item?/1)
    |> case do
      true ->
        []

      false ->
        [
          violation(
            "missing_testable_acceptance",
            "Add a non-placeholder Markdown list item under `Acceptance criteria`."
          )
        ]
    end
  end

  defp sections(description) do
    {sections, heading, body} =
      description
      |> String.split("\n")
      |> Enum.reduce({%{}, nil, []}, fn line, {sections, heading, body} ->
        case Regex.run(~r/^\s{0,3}[#]{1,6}\s+(.+?)\s*#*\s*$/, line, capture: :all_but_first) do
          [next_heading] -> {put_section(sections, heading, body), normalize(next_heading), []}
          nil -> {sections, heading, [line | body]}
        end
      end)

    put_section(sections, heading, body)
  end

  defp put_section(sections, nil, _body), do: sections

  defp put_section(sections, heading, body) do
    Map.put(sections, heading, body |> Enum.reverse() |> Enum.join("\n"))
  end

  defp unresolved_questions?(nil), do: false

  defp unresolved_questions?(body) do
    answers =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.replace(&1, ~r/^(?:[-*+]\s+|\d+[.)]\s+)/, ""))
      |> Enum.map(&normalize/1)

    answers != [] and Enum.any?(answers, &(&1 not in ["none", "无"]))
  end

  defp testable_acceptance_item?(item) do
    item = String.replace(item, ~r/^\[[ xX]\]\s*/, "")
    item != "" and not Regex.match?(@ambiguous_marker, item)
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp maybe_add(items, true, item), do: items ++ [item]
  defp maybe_add(items, false, _item), do: items

  defp violation(code, message), do: %{code: code, message: message}
end
