defmodule SymphonyElixir.Orchestrator.WorkerTaskPromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.Events

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

    profile = Config.workflow_profile_for_state(issue.state)

    prompt =
      PromptBuilder.build_prompt(issue,
        profile: profile,
        profile_policy: Config.workflow_profile(profile),
        allowed_updates: Config.workflow_allowed_updates(profile),
        attempt: 1
      )

    task_attrs =
      Events.worker_task_attrs(
        issue,
        %{id: "run-worker-prompt", project_id: "fake-project-id"},
        %{},
        prompt,
        profile
      )

    assert task_attrs.payload["prompt"] =~ "create_pull_request"
    assert task_attrs.payload["prompt"] =~ "Ready to Merge"
    assert task_attrs.payload["prompt"] =~ "Base worker prompt."
  end
end
