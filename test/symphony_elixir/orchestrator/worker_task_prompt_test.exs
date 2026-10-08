defmodule SymphonyElixir.Orchestrator.WorkerTaskPromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.RunAdmission

  test "worker task attrs carry the implementation profile prompt extension" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Base worker prompt.")

    issue = %Issue{
      id: "issue-worker-prompt",
      identifier: "SYM-66",
      title: "Include profile prompt in worker tasks",
      description: "The worker task must include handoff instructions.",
      state: "In Progress",
      branch_name: "feature/sym-66",
      url: "https://linear.example/SYM-66"
    }

    task_attrs =
      Config.with_workflow_context(workflow_context(), fn ->
        profile = Config.workflow_profile_for_state(issue.state)

        prompt =
          PromptBuilder.build_prompt(issue,
            profile: profile,
            profile_policy: Config.workflow_profile(profile),
            allowed_updates: Config.workflow_allowed_updates(profile),
            attempt: 1
          )

        Events.worker_assignment_payload(
          issue,
          %{id: "run-worker-prompt", project_id: "fake-project-id"},
          admission(issue),
          prompt,
          profile
        )
      end)

    assert task_attrs.payload["prompt"] =~ "create_pull_request"
    assert task_attrs.payload["prompt"] =~ "Ready to Merge"
    assert task_attrs.payload["prompt"] =~ "Base worker prompt."
  end

  test "worker task attrs carry the refinement profile from Refining state" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Base worker prompt.")

    issue = %Issue{
      id: "issue-worker-refinement-prompt",
      identifier: "SYM-67",
      title: "Refine a task",
      description: "The worker task must request refinement review.",
      state: "Refining",
      branch_name: "feature/sym-67",
      url: "https://linear.example/SYM-67"
    }

    task_attrs =
      Config.with_workflow_context(workflow_context(), fn ->
        profile = Config.workflow_profile_for_state(issue.state)

        prompt =
          PromptBuilder.build_prompt(issue,
            profile: profile,
            profile_policy: Config.workflow_profile(profile),
            allowed_updates: Config.workflow_allowed_updates(profile),
            attempt: 1
          )

        Events.worker_assignment_payload(
          issue,
          %{id: "run-worker-refinement-prompt", project_id: "fake-project-id"},
          admission(issue),
          prompt,
          profile
        )
      end)

    assert task_attrs.payload["issue"]["state"] == "Refining"
    assert task_attrs.payload["workflow_profile"] == "refinement"
    assert task_attrs.payload["handoff"]["allowed_updates"]["target_states"] == ["Needs Refinement Review"]
  end

  defp workflow_context do
    %{
      config: %{
        "project" => %{
          "repository_url" => "https://github.com/openai/symphony",
          "default_branch" => "main",
          "source_strategy" => "clone",
          "checkout_depth" => 1
        },
        "workspace" => %{"initialize_timeout_ms" => 60_000}
      },
      prompt_template: "Base worker prompt."
    }
  end

  defp admission(issue) do
    %RunAdmission{
      execution_mode: "worker",
      workspace_authority: {:http_worker, "worker-1", "session-1"},
      source: %{
        repository: "https://github.com/openai/symphony",
        default_branch: "main",
        implementation_branch: issue.branch_name,
        source_strategy: "clone",
        checkout_depth: 1
      },
      limits: %{
        initialize_timeout_ms: 60_000,
        max_turns: 20,
        max_failure_retries: 3,
        retry_backoff_ms: 300_000,
        turn_timeout_ms: 3_600_000,
        read_timeout_ms: 5_000,
        stall_timeout_ms: 600_000
      }
    }
  end
end
