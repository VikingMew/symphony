defmodule SymphonyElixir.Orchestrator.EventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.Events
  alias SymphonyElixir.RunAdmission
  alias SymphonyElixir.RunFailure

  test "issue attrs include the persisted issue snapshot" do
    issue =
      issue(
        labels: ["bug"],
        team_key: "KRN",
        project_slug: "koroni",
        dispatch_scope: %{linear_team_key: "KRN", linear_project_slug: nil, fallback_project_slug: "project-a"},
        context_source: "linear_project",
        symphony_project_id: "project-1",
        symphony_project_slug: "project-a"
      )

    assert Events.issue_attrs(issue) == %{
             tracker_issue_id: "issue-1",
             identifier: "MT-1",
             title: "Fix it",
             url: "https://linear.example/MT-1",
             labels: %{"values" => ["bug"]},
             snapshot: %{
               "id" => "issue-1",
               "identifier" => "MT-1",
               "title" => "Fix it",
               "description" => "Description",
               "priority" => 1,
               "state" => "Ready",
               "url" => "https://linear.example/MT-1",
               "labels" => ["bug"],
               "linear_team_key" => "KRN",
               "linear_project_slug" => "koroni",
               "dispatch_scope" => %{
                 "linear_team_key" => "KRN",
                 "linear_project_slug" => nil,
                 "fallback_project_slug" => "project-a"
               },
               "context_source" => "linear_project",
               "symphony_project_id" => "project-1",
               "symphony_project_slug" => "project-a"
             }
           }
  end

  test "run and assignment payload attrs preserve existing contract" do
    issue = issue()

    run = %{id: "run-1", project_id: "project-1"}
    admission = admission()

    run_attrs = Events.run_attrs(issue, admission, 2)
    assert run_attrs.issue_identifier == "MT-1"
    assert run_attrs.status == "running"
    assert run_attrs.execution_mode == "worker"
    assert run_attrs.attempt == 2

    assignment_attrs =
      SymphonyElixir.Config.with_workflow_context(workflow_context(), fn ->
        Events.worker_assignment_payload(issue, run, admission, "Prompt", "implementation")
      end)

    payload = assignment_attrs.payload

    assert payload["issue"]["identifier"] == "MT-1"
    assert payload["prompt"] == "Prompt"
    assert payload["workflow_profile"] == "implementation"
    assert payload["execution_mode"] == "worker"

    assert Enum.map(payload["required_gates"], & &1["command"]) == [
             "scripts/check.sh",
             "scripts/unit.sh",
             "scripts/dialyzer.sh"
           ]

    assert payload["source"] == %{
             "repository" => "https://decision.example/repo.git",
             "default_branch" => "trunk",
             "implementation_branch" => "feature/mt-1",
             "source_strategy" => "clone",
             "checkout_depth" => 7
           }

    assert Map.has_key?(payload, "repository") == false
    assert payload["codex"]["model"] == "gpt-5.5"
    assert payload["codex"]["reasoning_effort"] == "xhigh"
    assert payload["limits"]["stall_timeout_ms"] == 600_000
    assert payload["limits"]["initialize_timeout_ms"] == 61_001
    assert payload["limits"]["retry_backoff_ms"] == 300_000
    assert recursively_has_key?(payload, "workflow_version_id") == false
  end

  test "assignment gates follow the resolved workflow profile" do
    configured_gates = workflow_context().config["project"]["required_gates"]

    for gates <- [configured_gates, []] do
      {implementation, refinement, project_gates} =
        Config.with_workflow_context(workflow_context_with_gates(gates), fn ->
          implementation_profile = Config.workflow_profile_for_state("In Progress")
          refinement_profile = Config.workflow_profile_for_state("Refining")

          implementation =
            Events.worker_assignment_payload(
              issue(state: "In Progress"),
              %{id: "run-implementation", project_id: "project-1"},
              admission(),
              "Prompt",
              implementation_profile
            )

          refinement =
            Events.worker_assignment_payload(
              issue(state: "Refining"),
              %{id: "run-refinement", project_id: "project-1"},
              admission(),
              "Prompt",
              refinement_profile
            )

          {implementation, refinement, Config.settings!().project.required_gates}
        end)

      assert implementation.payload["workflow_profile"] == "implementation"
      assert implementation.payload["required_gates"] == project_gates
      assert refinement.payload["workflow_profile"] == "refinement"
      assert refinement.payload["required_gates"] == []
    end
  end

  test "event attrs cover run and workspace events" do
    issue = issue()
    run = %{id: "run-1"}
    running_entry = %{identifier: "MT-1", run_id: "run-1", workspace_path: "/tmp/work", worker_host: "worker-a"}

    assert Events.run_started_event(issue, run, "worker-a") ==
             Events.event_attrs("run.started", "MT-1", %{issue_id: "issue-1", run_id: "run-1", worker_host: "worker-a"}, "run-1")

    failure = RunFailure.classify({:runtime_failure, %{reason: "worker_error", detail: "boom"}})

    assert Events.run_finished_event(running_entry, "failed", failure).payload == %{
             run_id: "run-1",
             failure_reason: "runtime_failure",
             failure_evidence: %{"detail" => "boom", "reason" => "worker_error"}
           }

    assert Events.workspace_attrs(running_entry) == %{
             issue_identifier: "MT-1",
             path: "/tmp/work",
             host: "worker-a",
             status: "active"
           }

    assert Events.workspace_created_event(running_entry).payload == %{path: "/tmp/work", host: "worker-a"}
  end

  defp issue(attrs \\ []) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: "issue-1",
          identifier: "MT-1",
          title: "Fix it",
          description: "Description",
          priority: 1,
          state: "Ready",
          url: "https://linear.example/MT-1",
          branch_name: "feature/mt-1",
          labels: []
        ],
        attrs
      )
    )
  end

  defp workflow_context do
    %{
      config: %{
        "project" => %{
          "repository_url" => "https://github.com/openai/symphony",
          "default_branch" => "main",
          "source_strategy" => "clone",
          "checkout_depth" => 1,
          "required_gates" => default_required_gates()
        },
        "workspace" => %{"initialize_timeout_ms" => 60_000},
        "codex" => %{
          "model" => "gpt-5.5",
          "reasoning_effort" => "xhigh"
        }
      },
      prompt_template: "Prompt"
    }
  end

  defp workflow_context_with_gates(required_gates) do
    put_in(workflow_context().config["project"]["required_gates"], required_gates)
  end

  defp default_required_gates do
    [
      %{"name" => "check", "command" => "scripts/check.sh", "timeout_ms" => 300_000},
      %{"name" => "unit", "command" => "scripts/unit.sh", "timeout_ms" => 1_800_000},
      %{"name" => "dialyzer", "command" => "scripts/dialyzer.sh", "timeout_ms" => 1_800_000}
    ]
  end

  defp admission do
    %RunAdmission{
      execution_mode: "worker",
      workspace_authority: {:http_worker, "worker-1", "session-1"},
      source: %{
        repository: "https://decision.example/repo.git",
        default_branch: "trunk",
        implementation_branch: "feature/mt-1",
        source_strategy: "clone",
        checkout_depth: 7
      },
      limits: %{
        initialize_timeout_ms: 61_001,
        max_turns: 20,
        max_failure_retries: 3,
        retry_backoff_ms: 300_000,
        turn_timeout_ms: 3_600_000,
        read_timeout_ms: 5_000,
        stall_timeout_ms: 600_000
      }
    }
  end

  defp recursively_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &recursively_has_key?(&1, key))
  end

  defp recursively_has_key?(list, key) when is_list(list), do: Enum.any?(list, &recursively_has_key?(&1, key))
  defp recursively_has_key?(_value, _key), do: false
end
