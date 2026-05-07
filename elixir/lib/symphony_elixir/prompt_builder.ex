defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    assigns = prompt_assigns(issue, opts)

    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(assigns, @render_opts)
    |> IO.iodata_to_binary()
    |> apply_profile_prompt(opts, assigns)
  end

  defp prompt_assigns(issue, opts) do
    %{
      "attempt" => Keyword.get(opts, :attempt),
      "issue" => issue |> Map.from_struct() |> to_solid_map(),
      "workflow" => %{
        "profile" => Keyword.get(opts, :profile),
        "profile_name" => get_in(Keyword.get(opts, :profile_policy, %{}), ["name"]),
        "allowed_updates" => Keyword.get(opts, :allowed_updates, %{}),
        "activity_summary" => Keyword.get(opts, :activity_summary)
      }
    }
  end

  defp apply_profile_prompt(prompt, opts, assigns) do
    if is_nil(Keyword.get(opts, :profile)) do
      prompt
    else
      do_apply_profile_prompt(prompt, opts, assigns)
    end
  end

  defp do_apply_profile_prompt(prompt, opts, assigns) do
    profile_policy = Keyword.get(opts, :profile_policy, %{})
    prompt_policy = Map.get(profile_policy, "prompt", %{})

    case Map.get(prompt_policy, "mode", "extend") do
      "replace" ->
        render_stage_template!(Map.get(prompt_policy, "template", ""), assigns)

      "disabled" ->
        prompt

      "extend" ->
        extend_profile_prompt(opts, assigns) <> "\n\n" <> prompt
    end
  end

  defp extend_profile_prompt(opts, assigns) do
    prompt_policy =
      opts
      |> Keyword.get(:profile_policy, %{})
      |> Map.get("prompt", %{})

    case Map.get(prompt_policy, "template") do
      template when is_binary(template) and template != "" ->
        render_stage_template!(template, assigns)

      _ ->
        profile_contract(Keyword.get(opts, :profile), Keyword.get(opts, :allowed_updates, %{}))
    end
  end

  defp render_stage_template!(template, assigns) when is_binary(template) do
    template
    |> parse_template!()
    |> Solid.render!(assigns, @render_opts)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp profile_contract("refinement", allowed_updates) do
    """
    Workflow profile: refinement

    First read the task and recent activity with `linear_task_read`; comments may contain reviewer feedback that changes the required work. Refine the task description and acceptance criteria only when the feedback and repository context justify it. When the task is ready for human confirmation, use `linear_task_update` to add a concise comment and request one of these states: #{target_states_text(allowed_updates)}.
    """
    |> String.trim()
  end

  defp profile_contract("implementation", allowed_updates) do
    """
    Workflow profile: implementation

    First read the task and recent activity with `linear_task_read`; comments may contain rejection feedback or scope changes. Implement, test, and verify the code in the worktree. When ready for human implementation review, use `linear_task_update` to add the result, relevant references, a concise comment, and request one of these states: #{target_states_text(allowed_updates)}.
    """
    |> String.trim()
  end

  defp profile_contract("merge", allowed_updates) do
    """
    Workflow profile: merge

    First read the task and recent activity with `linear_task_read`; comments may contain reviewer constraints. Verify the branch is ready to merge, perform the merge workflow when allowed, and use `linear_task_update` with a concise result comment and one of these states: #{target_states_text(allowed_updates)}.
    """
    |> String.trim()
  end

  defp profile_contract(profile, allowed_updates) when is_binary(profile) do
    """
    Workflow profile: #{profile}

    First read the task and recent activity with `linear_task_read`; comments may contain reviewer feedback that changes the required work. Follow this profile's instructions and use `linear_task_update` only for allowed updates and target states: #{target_states_text(allowed_updates)}.
    """
    |> String.trim()
  end

  defp profile_contract(_profile, _allowed_updates), do: ""

  defp target_states_text(%{"target_states" => states}) when is_list(states) and states != [] do
    Enum.join(states, ", ")
  end

  defp target_states_text(_allowed_updates), do: "the profile's allowed target states"

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
