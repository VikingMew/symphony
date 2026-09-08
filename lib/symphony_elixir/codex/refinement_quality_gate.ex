defmodule SymphonyElixir.Codex.RefinementQualityGate do
  @moduledoc false

  @required_sections [
    {"goal", "Goal"},
    {"owning design docs", "Owning design docs"},
    {"scope", "Scope"},
    {"out of scope", "Out of scope"},
    {"acceptance criteria", "Acceptance criteria"},
    {"validation", "Validation"}
  ]
  @ambiguous_marker ~r/\[NEEDS CLARIFICATION\]|\[TODO\]|TODO:|TBD|\?\?\?/i
  @context_marker ~r/\[CONTEXT REQUIRED\]/i
  @list_item ~r/^\s*(?:[-*+]\s+|\d+[.)]\s+)(.+)$/
  @question_sections ["open questions", "unresolved questions", "未决问题"]
  @owner_path ~r/docs\/[A-Za-z0-9_.\/-]+-design\.md/
  @no_owner_marker ~r/^\s*No owner:\s*true\s*$/mi
  @owner_registration_plan ~r/^\s*(?:[-*+]\s+)?(?:\[[ xX]\]\s+)?Owner registration plan:\s*\S.*$/mi

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
        owning_design_violations(sections) ++
        marker_violations(description) ++
        unresolved_question_violations(sections) ++ acceptance_violations(sections)

    case Enum.uniq(violations) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp owning_design_violations(sections) do
    case Map.get(sections, "owning design docs") do
      body when is_binary(body) -> if(blank?(body), do: [], else: validate_owning_design(body, sections))
      _ -> []
    end
  end

  defp validate_owning_design(body, sections) do
    classification = declaration(body, "Change classification")
    design_sync = declaration(body, "Design sync")
    owners = @owner_path |> Regex.scan(body) |> List.flatten() |> Enum.uniq()
    no_owner? = Regex.match?(@no_owner_marker, body)

    classification_violations(classification) ++
      design_sync_violations(design_sync) ++
      behavior_design_violations(classification, design_sync, owners, no_owner?, sections) ++
      non_behavior_design_violations(classification, design_sync, body) ++
      required_design_sync_violations(design_sync, owners, no_owner?, sections)
  end

  defp classification_violations(nil),
    do: [violation("missing_change_classification", "Add `Change classification: behavior/architecture|non-behavior`.")]

  defp classification_violations(value) when value in ["behavior/architecture", "non-behavior"], do: []

  defp classification_violations(_value),
    do: [violation("invalid_change_classification", "Use `behavior/architecture` or `non-behavior` for `Change classification`.")]

  defp design_sync_violations(nil),
    do: [violation("missing_design_sync", "Add `Design sync: required|not required`.")]

  defp design_sync_violations(value) when value in ["required", "not required"], do: []

  defp design_sync_violations(_value),
    do: [violation("invalid_design_sync", "Use `required` or `not required` for `Design sync`.")]

  defp behavior_design_violations("behavior/architecture", design_sync, owners, no_owner?, sections) do
    []
    |> maybe_add(
      design_sync == "not required",
      violation("behavior_design_sync_not_required", "Set `Design sync: required` for `behavior/architecture` changes.")
    )
    |> maybe_add(
      owners == [] and not no_owner?,
      violation("missing_owning_design", "List a `docs/*-design.md` owner or add `No owner: true`.")
    )
    |> maybe_add(
      no_owner? and not owner_registration_planned?(sections),
      violation(
        "missing_owner_registration_plan",
        "Add a non-empty `Owner registration plan:` item to both `Scope` and `Acceptance criteria`."
      )
    )
  end

  defp behavior_design_violations(_classification, _design_sync, _owners, _no_owner?, _sections), do: []

  defp non_behavior_design_violations("non-behavior", "not required", body) do
    if declaration(body, "Reason") in [nil, ""] do
      [violation("missing_design_sync_reason", "Add a non-empty `Reason:` for `non-behavior` with `Design sync: not required`.")]
    else
      []
    end
  end

  defp non_behavior_design_violations(_classification, _design_sync, _body), do: []

  defp required_design_sync_violations("required", owners, no_owner?, sections) do
    scope = Map.get(sections, "scope", "")
    acceptance = Map.get(sections, "acceptance criteria", "")

    []
    |> maybe_add(
      owners != [] and Enum.any?(owners, &(not String.contains?(scope, &1))),
      violation("design_sync_missing_from_scope", "Reference every listed owning design in `Scope`.")
    )
    |> maybe_add(
      owners != [] and Enum.any?(owners, &(not String.contains?(acceptance, &1))),
      violation("design_sync_missing_from_acceptance", "Reference every listed owning design in `Acceptance criteria`.")
    )
    |> maybe_add(
      owners == [] and no_owner? and not Regex.match?(@owner_registration_plan, scope),
      violation("design_sync_missing_from_scope", "Add the `Owner registration plan:` item to `Scope`.")
    )
    |> maybe_add(
      owners == [] and no_owner? and not Regex.match?(@owner_registration_plan, acceptance),
      violation("design_sync_missing_from_acceptance", "Add the `Owner registration plan:` item to `Acceptance criteria`.")
    )
  end

  defp required_design_sync_violations(_design_sync, _owners, _no_owner?, _sections), do: []

  defp owner_registration_planned?(sections) do
    Enum.all?(["scope", "acceptance criteria"], fn section ->
      Regex.match?(@owner_registration_plan, Map.get(sections, section, ""))
    end)
  end

  defp declaration(body, field) do
    case Regex.run(~r/^\s*#{Regex.escape(field)}:\s*(.*?)\s*$/mi, body, capture: :all_but_first) do
      [value] -> normalize(value)
      nil -> nil
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
