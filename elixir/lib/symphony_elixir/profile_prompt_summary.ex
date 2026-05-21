defmodule SymphonyElixir.ProfilePromptSummary do
  @moduledoc """
  Display-only prompt composition summaries for workflow profiles.
  """

  alias SymphonyElixir.Text

  @type profile_summary :: %{
          profile_id: String.t(),
          executor_type: String.t(),
          mode: String.t(),
          template_chars: non_neg_integer(),
          effective_chars: non_neg_integer() | nil,
          uses_base_prompt?: boolean(),
          prompt_used?: boolean(),
          composition: String.t(),
          warning: String.t() | nil,
          preview: String.t()
        }

  @spec page_summary(String.t(), map()) :: map()
  def page_summary(base_prompt, profiles) when is_map(profiles) do
    summaries = Enum.map(profiles, fn {profile_id, profile} -> profile_summary(base_prompt, profile_id, profile) end)

    %{
      base_chars: char_count(base_prompt),
      profiles_with_templates: Enum.count(summaries, &(&1.template_chars > 0)),
      profiles_with_warnings: Enum.count(summaries, & &1.warning),
      disabled_profiles: Enum.count(summaries, &(&1.mode == "disabled"))
    }
  end

  @spec profile_summary(String.t(), String.t(), map()) :: profile_summary()
  def profile_summary(base_prompt, profile_id, profile) when is_map(profile) do
    executor = string_value(profile, "executor_type", "codex_agent")
    mode = string_value(profile, "prompt_mode", "extend")
    template = string_value(profile, "prompt_template", "")
    base_prompt = to_string(base_prompt || "")

    summary =
      %{
        profile_id: to_string(profile_id),
        executor_type: executor,
        mode: mode,
        template_chars: char_count(template),
        effective_chars: effective_chars(base_prompt, template, executor, mode),
        uses_base_prompt?: uses_base_prompt?(executor, mode),
        prompt_used?: prompt_used?(base_prompt, template, executor, mode),
        composition: composition(base_prompt, template, executor, mode),
        warning: warning(base_prompt, template, executor, mode)
      }

    Map.put(summary, :preview, preview(base_prompt, template, summary))
  end

  def profile_summary(base_prompt, profile_id, _profile), do: profile_summary(base_prompt, profile_id, %{})

  defp effective_chars(_base_prompt, _template, executor, _mode) when executor != "codex_agent", do: nil
  defp effective_chars(_base_prompt, template, _executor, "replace"), do: char_count(template)
  defp effective_chars(base_prompt, _template, _executor, "disabled"), do: char_count(base_prompt)
  defp effective_chars(base_prompt, template, _executor, _mode), do: combined_count(base_prompt, template)

  defp uses_base_prompt?(executor, _mode) when executor != "codex_agent", do: false
  defp uses_base_prompt?(_executor, "replace"), do: false
  defp uses_base_prompt?(_executor, _mode), do: true

  defp prompt_used?(base_prompt, template, executor, mode) do
    case effective_chars(base_prompt, template, executor, mode) do
      nil -> false
      count -> count > 0
    end
  end

  defp composition(_base_prompt, _template, executor, _mode) when executor != "codex_agent" do
    "Prompt fields are not used by this executor."
  end

  defp composition(_base_prompt, _template, _executor, "replace"), do: "Profile template replaces the Base Prompt."
  defp composition(_base_prompt, _template, _executor, "disabled"), do: "Profile prompt is disabled; Base Prompt is used by itself."
  defp composition(_base_prompt, _template, _executor, _mode), do: "Profile template extends the Base Prompt."

  defp warning(_base_prompt, _template, executor, _mode) when executor != "codex_agent", do: nil

  defp warning(_base_prompt, template, _executor, "replace") do
    if blank?(template), do: "Codex profile replaces the Base Prompt but has no profile prompt template.", else: nil
  end

  defp warning(base_prompt, _template, _executor, "disabled") do
    if blank?(base_prompt), do: "Codex profile prompt is disabled and the Base Prompt is empty.", else: nil
  end

  defp warning(base_prompt, template, _executor, _mode) do
    cond do
      blank?(base_prompt) and blank?(template) -> "Codex profile has no useful Base Prompt or profile prompt template."
      blank?(template) -> "Codex profile extends the Base Prompt but has no stage-specific prompt template."
      true -> nil
    end
  end

  defp preview(_base_prompt, _template, %{executor_type: executor}) when executor != "codex_agent",
    do: "This executor does not receive a Codex prompt from these fields."

  defp preview(_base_prompt, template, %{mode: "replace"}), do: blank_preview(template)
  defp preview(base_prompt, _template, %{mode: "disabled"}), do: blank_preview(base_prompt)

  defp preview(base_prompt, template, _summary) do
    [template, base_prompt]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> blank_preview()
  end

  defp combined_count(base_prompt, template) do
    case {blank?(base_prompt), blank?(template)} do
      {true, true} -> 0
      {true, false} -> char_count(template)
      {false, true} -> char_count(base_prompt)
      {false, false} -> char_count(template) + 2 + char_count(base_prompt)
    end
  end

  defp blank_preview(value) do
    if blank?(value), do: "No prompt text.", else: value
  end

  defp string_value(map, key, default), do: to_string(Map.get(map, key) || Map.get(map, atom_key(key)) || default)
  defp atom_key("executor_type"), do: :executor_type
  defp atom_key("prompt_mode"), do: :prompt_mode
  defp atom_key("prompt_template"), do: :prompt_template
  defp atom_key(_key), do: nil
  defp char_count(value), do: value |> to_string() |> String.length()
  defp blank?(value), do: Text.blankish?(value)
end
