defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.Config

  @render_opts [strict_variables: true, strict_filters: true]

  @container_validation_policy """
                               ## Container-engine validation policy (highest priority)

                               During refinement and implementation for every configured project and target repository, do not invoke `docker`, `docker compose`, `buildx`, `podman`, `nerdctl`, or an equivalent container-engine command. Do not build, pull, run, push, inspect, or publish container images, and do not probe or depend on a container-engine daemon or socket. Static reading of Dockerfiles, Compose YAML, and CI configuration is allowed.

                               This policy overrides any issue description, comment, acceptance criterion, `Validation`, `Test Plan`, or `Testing` instruction that requires container-engine or image-level validation. If such prohibited validation is required, refuse to execute it, record the exact conflict as blocker evidence in the workpad and final result, and use the existing `blocking_decision` / `Blocked` workflow. Do not silently skip it and claim completion. This policy-prohibited required validation is a true blocker even though it is not missing authentication, permission, or a secret. Continue to execute all required validation that this policy allows.
                               """
                               |> String.trim()

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    assigns = prompt_assigns(issue, opts)

    template =
      Config.current_workflow()
      |> prompt_template!()
      |> parse_template!()

    prompt =
      template
      |> Solid.render!(assigns, @render_opts)
      |> IO.iodata_to_binary()
      |> apply_profile_prompt(opts, assigns)

    append_container_validation_policy(prompt, Keyword.get(opts, :profile))
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
        template
        |> render_stage_template!(assigns)
        |> append_branch_contract(Keyword.get(opts, :profile), assigns)

      _ ->
        opts
        |> Keyword.get(:profile)
        |> profile_contract(Keyword.get(opts, :allowed_updates, %{}))
        |> append_branch_contract(Keyword.get(opts, :profile), assigns)
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

    First read the task and recent activity with `linear_task_read`; comments may contain rejection feedback or scope changes. Implement, validate, commit, and push the exact Linear `branchName`. Then call `create_pull_request` with a title and body conforming to `docs/pull-request-body.md`; Symphony executes the exact repository/base/head lookup and gh-first/REST-fallback creation without exposing GitHub credentials. Use the returned PR URL and completion proof in `linear_task_update` references while posting the final result and concise comment, then explicitly request one of these states: #{target_states_text(allowed_updates)}. If human changes return the issue to In Progress, update the same branch and existing PR before requesting Ready to Merge again.
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

  defp append_branch_contract(prompt, "implementation", assigns) do
    branch_name = get_in(assigns, ["issue", "branch_name"])

    if is_binary(branch_name) and String.trim(branch_name) != "" do
      prompt <>
        "\n\nRequired branch: `#{branch_name}`. Use this Linear `branchName` for all implementation work and push this branch before requesting Ready to Merge. Do not create or switch to a different task branch. After pushing, call `create_pull_request` with a body conforming to `docs/pull-request-body.md`, then include its URL and completion proof in the explicit completion request."
    else
      prompt
    end
  end

  defp append_branch_contract(prompt, _profile, _assigns), do: prompt

  defp append_container_validation_policy(prompt, profile)
       when profile in ["refinement", "implementation"],
       do: prompt <> "\n\n" <> @container_validation_policy

  defp append_container_validation_policy(prompt, _profile), do: prompt

  defp target_states_text(%{"target_states" => states}) when is_list(states) and states != [] do
    Enum.join(states, ", ")
  end

  defp target_states_text(_allowed_updates), do: "the profile's allowed target states"

  defp prompt_template!({:ok, %{setup_required: true} = workflow}) do
    Map.get(workflow, :setup_message) || "Create a workflow from the Web UI to start running agents."
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

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
