defmodule SymphonyElixir.WebFakePersistenceTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.TestSupport.FakePersistence

  @endpoint SymphonyElixirWeb.Endpoint
  @worker_token "fake-worker-token"

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_worker_api = Application.get_env(:symphony_elixir, :worker_api)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    Application.put_env(:symphony_elixir, :worker_api, registration_token: @worker_token)
    System.put_env("LINEAR_API_KEY", "fake-linear-token")
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous_endpoint)
      restore_app_env(:worker_api, previous_worker_api)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    :ok
  end

  test "projects page renders fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, _view, html} = live(build_conn(), "/projects")

    assert html =~ "Fake Project"
    assert html =~ "fake"
  end

  test "run detail, issue detail, and events pages render persisted observability data" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    now = DateTime.utc_now()

    run = %{
      id: "run-1",
      workflow_version_id: "workflow-1",
      issue_identifier: "MT-1",
      workspace_path: "/tmp/workspaces/MT-1",
      status: "failed",
      attempt: 2,
      failure_reason: "boom",
      started_at: now,
      finished_at: now
    }

    workflow_version = %{
      id: "workflow-1",
      project_id: "fake-project-id",
      version: 7,
      source: "web_form",
      active: true,
      inserted_at: now,
      raw_workflow_md: workflow_import_raw("git@github.com:org/repo.git")
    }

    FakePersistence.put_runs([run])
    FakePersistence.put_issues([%{identifier: "MT-1", state: "In Progress", title: "Issue detail"}])
    FakePersistence.put_workflow_versions([workflow_version], workflow_version)

    FakePersistence.put_agent_turns([
      %{run_id: "run-1", turn_index: 1, status: "failed", summary: "Turn failed", started_at: now, finished_at: now}
    ])

    FakePersistence.put_events([
      %{
        run_id: "run-1",
        issue_identifier: "MT-1",
        event_type: "run.failed",
        payload: %{"api_token" => "secret", "message" => "boom"},
        occurred_at: now
      }
    ])

    {:ok, _view, run_html} = live(build_conn(), "/runs/run-1")
    assert run_html =~ "Run Detail"
    assert run_html =~ "MT-1"
    assert run_html =~ "Workflow Version"
    assert run_html =~ "Turn failed"
    assert run_html =~ "[REDACTED]"
    refute run_html =~ "secret"

    {:ok, _view, issue_html} = live(build_conn(), "/issues/MT-1")
    assert issue_html =~ "Issue Detail"
    assert issue_html =~ "Issue detail"
    assert issue_html =~ "run-1"

    {:ok, _view, events_html} = live(build_conn(), "/events")
    assert events_html =~ "Events"
    assert events_html =~ "run.failed"

    {:ok, _view, filtered_events_html} = live(build_conn(), "/events?issue_identifier=MT-MISSING")
    assert filtered_events_html =~ "No events recorded"
    refute filtered_events_html =~ "run.failed"
  end

  test "workflow page saves structured draft through fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, html} = live(build_conn(), "/workflows")
    assert html =~ "Draft Configuration"
    assert html =~ "Project slug"
    assert html =~ "Lifecycle Hooks"
    assert html =~ "Hook timeout ms"
    assert html =~ ~s(phx-disable-with="Saving...")
    refute html =~ "Raw WORKFLOW.md"
    refute html =~ "workflow[tracker_kind]"
    refute html =~ "workflow[tracker_endpoint]"
    refute html =~ "workflow[tracker_api_key]"
    refute html =~ "API key"

    params =
      workflow_form_params()
      |> Map.put("workspace_root", "/tmp/structured-workspaces")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "Runtime workflow refreshed"
    assert html =~ "workflow-save-toast-success"
    assert html =~ "Workflow saved"
    assert html =~ "Version 1 is active"

    assert {:import_workflow, %{id: "fake-project-id"}, raw, "web_form"} =
             Enum.find(FakePersistence.calls(), fn
               {:import_workflow, %{id: "fake-project-id"}, _raw, "web_form"} -> true
               _ -> false
             end)

    assert raw =~ "/tmp/structured-workspaces"
    assert raw =~ "api_key"
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert get_in(loaded_workflow.config, ["tracker", "kind"]) == "linear"
    assert get_in(loaded_workflow.config, ["tracker", "endpoint"]) == "https://api.linear.app/graphql"
    assert {:ok, _validation} = SymphonyElixir.WorkflowValidator.validate_raw(raw)
  end

  test "workflow form saves and clears lifecycle hooks" do
    draft =
      SymphonyElixir.WorkflowForm.from_loaded(%{
        config: %{
          "tracker" => %{
            "kind" => "linear",
            "endpoint" => "https://api.linear.app/graphql",
            "api_key" => "$LINEAR_API_KEY",
            "project_slug" => "project",
            "active_states" => ["Ready"],
            "terminal_states" => ["Done"]
          },
          "polling" => %{"interval_ms" => 30_000},
          "project" => %{"repository_url" => "git@github.com:org/repo.git"},
          "hooks" => %{
            "timeout_ms" => 60_000,
            "after_create" => "echo stale",
            "before_run" => "echo before"
          }
        },
        prompt: "Hook prompt"
      })

    assert draft["hook_after_create"] == "echo stale"
    assert draft["hook_before_run"] == "echo before"

    edited =
      draft
      |> Map.put("hook_after_create", "")
      |> Map.put("hook_before_run", "echo edited")
      |> Map.put("hook_after_run", "echo after")
      |> Map.put("hook_before_remove", "echo remove")
      |> Map.put("hook_timeout_ms", "45000")

    assert {:ok, raw} = SymphonyElixir.WorkflowForm.to_raw(edited)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)

    hooks = get_in(loaded_workflow.config, ["hooks"])
    refute Map.has_key?(hooks, "after_create")
    assert hooks["before_run"] == "echo edited"
    assert hooks["after_run"] == "echo after"
    assert hooks["before_remove"] == "echo remove"
    assert hooks["timeout_ms"] == 45_000
  end

  test "workflow form rejects invalid lifecycle hook timeout" do
    draft =
      workflow_form_params()
      |> Map.put("_base_config", %{})
      |> Map.put("hook_timeout_ms", "0")

    assert {:error, "Hook timeout must be a positive integer"} =
             SymphonyElixir.WorkflowForm.to_raw(draft)
  end

  test "workflow form saves legacy tracker drafts as linear" do
    draft =
      SymphonyElixir.WorkflowForm.from_loaded(%{
        config: %{
          "tracker" => %{
            "kind" => "legacy-local",
            "project_slug" => "legacy",
            "active_states" => ["Todo"],
            "terminal_states" => ["Done"]
          },
          "polling" => %{"interval_ms" => 30_000}
        },
        prompt: "Legacy prompt"
      })

    assert SymphonyElixir.WorkflowForm.summary(draft).tracker == "linear"
    assert {:ok, raw} = SymphonyElixir.WorkflowForm.to_raw(draft)
    assert {:ok, loaded_workflow} = SymphonyElixir.Workflow.parse_content(raw)
    assert get_in(loaded_workflow.config, ["tracker", "kind"]) == "linear"
    assert get_in(loaded_workflow.config, ["tracker", "endpoint"]) == "https://api.linear.app/graphql"
    assert get_in(loaded_workflow.config, ["tracker", "api_key"]) == "$LINEAR_API_KEY"
  end

  test "workflow page rejects invalid structured draft before import" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/workflows")

    params =
      workflow_form_params()
      |> Map.put("polling_interval_ms", "bad")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: params)
      |> render_submit()

    assert html =~ "Validation failed"
    assert html =~ "workflow-save-toast-error"
    assert html =~ "Workflow save failed"
    assert html =~ "Polling interval must be a positive integer"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)
  end

  test "workflow page shows popup feedback when save persistence fails" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()
    FakePersistence.fail_next_import_workflow!(:database_unavailable)

    {:ok, view, _html} = live(build_conn(), "/workflows")

    html =
      view
      |> form("form[phx-submit='save_workflow_form']", workflow: workflow_form_params())
      |> render_submit()

    assert html =~ "workflow-save-toast-error"
    assert html =~ "Workflow save failed"
    assert html =~ "database_unavailable"
    refute html =~ "workflow-save-toast-success"

    assert Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, %{id: "fake-project-id"}, _raw, "web_form"} -> true
             _ -> false
           end)
  end

  test "workflow page imports workflow file into structured draft without saving" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/workflows")
    raw = workflow_import_raw("git@github.com:org/imported.git")

    upload =
      file_input(view, ".workflow-import-form", :workflow_import, [
        %{
          last_modified: 1_700_000_000_000,
          name: "WORKFLOW.md",
          content: raw,
          size: byte_size(raw),
          type: "text/markdown"
        }
      ])

    render_upload(upload, "WORKFLOW.md")

    html =
      view
      |> form(".workflow-import-form", %{})
      |> render_submit()

    assert html =~ "git@github.com:org/imported.git"
    assert html =~ "Profiles"
    assert html =~ "implementation"
    assert html =~ "Workflow Phases / State Routing"
    assert html =~ "Ready"
    refute html =~ "$LINEAR_API_KEY"

    refute Enum.any?(FakePersistence.calls(), fn
             {:import_workflow, _project, _raw, _source} -> true
             _ -> false
           end)
  end

  test "workflow page refuses to activate an invalid historical workflow version" do
    refute Process.whereis(SymphonyElixir.Repo)

    invalid = %{
      id: "invalid-version",
      project_id: "fake-project-id",
      version: 2,
      source: "web",
      active: false,
      inserted_at: DateTime.utc_now(),
      raw_workflow_md: "---\nworkflow:\n  allowed_transitions:\n    - {from: Ready, to: Done, actor: robot}\n---\nPrompt\n"
    }

    FakePersistence.put_workflow_versions([invalid])
    start_test_endpoint()

    {:ok, view, _html} = live(build_conn(), "/workflows")
    html = render_click(view, "activate_workflow", %{"id" => "invalid-version"})

    assert html =~ "Validation failed"
    assert html =~ "allowed_transitions.actor"

    refute Enum.any?(FakePersistence.calls(), fn
             {:activate_workflow_version, ^invalid} -> true
             _ -> false
           end)
  end

  test "worker API uses fake persistence without Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    start_test_endpoint()

    assert %{"error" => %{"code" => "worker_unauthorized"}} =
             build_conn()
             |> put_req_header("authorization", "Bearer wrong")
             |> post("/api/worker/v1/register", worker_registration_payload())
             |> json_response(401)

    assert %{
             "worker_id" => worker_id,
             "session_id" => session_id,
             "accepted_protocol_version" => "worker-api-v1"
           } =
             build_conn()
             |> put_req_header("authorization", "Bearer #{@worker_token}")
             |> post("/api/worker/v1/register", worker_registration_payload())
             |> json_response(200)

    assert %{"task" => nil} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/claim", %{"available_slots" => 1})
             |> json_response(200)

    assert %{"ok" => true, "lease_renewals" => []} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/heartbeat", %{"active_leases" => []})
             |> json_response(200)

    assert %{"accepted" => true} =
             build_conn()
             |> worker_headers(worker_id, session_id)
             |> post("/api/worker/v1/tasks/fake-task/events", %{"event_type" => "task.completed", "payload" => %{}})
             |> json_response(202)

    assert Enum.any?(FakePersistence.calls(), fn
             {:register_worker, %{"worker_name" => "fake-worker"}} -> true
             _ -> false
           end)
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp worker_registration_payload do
    %{
      "worker_name" => "fake-worker",
      "worker_version" => "0.1.0",
      "protocol_version" => "worker-api-v1",
      "instance_id" => "test-instance"
    }
  end

  defp worker_headers(conn, worker_id, session_id) do
    conn
    |> put_req_header("x-symphony-worker-protocol", "worker-api-v1")
    |> put_req_header("x-symphony-worker-id", worker_id)
    |> put_req_header("x-symphony-worker-session", session_id)
  end

  defp workflow_form_params do
    %{
      "tracker_project_slug" => "project",
      "tracker_assignee" => "",
      "active_states" => "Refining\nReady\nIn Progress\nReady to Merge\nMerging",
      "terminal_states" => "Canceled\nCancelled\nDuplicate\nDone",
      "polling_interval_ms" => "30000",
      "project_repository_url" => "git@github.com:org/repo.git",
      "project_default_branch" => "main",
      "project_checkout_depth" => "1",
      "project_setup_commands" => "mix deps.get",
      "project_cleanup_commands" => "",
      "workspace_root" => "/tmp/symphony-workspaces",
      "agent_max_concurrent_agents" => "1",
      "agent_max_turns" => "20",
      "codex_command" => "codex app-server",
      "codex_thread_sandbox" => "workspace-write",
      "hook_after_create" => "",
      "hook_before_run" => "",
      "hook_after_run" => "",
      "hook_before_remove" => "",
      "hook_timeout_ms" => "60000",
      "prompt_body" => "You are an agent for this repository."
    }
  end

  defp workflow_import_raw(repository_url) do
    """
    ---
    tracker:
      kind: linear
      endpoint: "https://api.linear.app/graphql"
      api_key: "$LINEAR_API_KEY"
      project_slug: "project"
      active_states: ["Refining", "Ready", "In Progress", "Ready to Merge", "Merging"]
      terminal_states: ["Canceled", "Cancelled", "Duplicate", "Done"]
    polling:
      interval_ms: 30000
    project:
      repository_url: "#{repository_url}"
      default_branch: "main"
      checkout_depth: 1
      setup_commands: ["mix deps.get"]
      cleanup_commands: []
    workspace:
      root: "/tmp/imported-workspaces"
    agent:
      max_concurrent_agents: 1
      max_turns: 20
    codex:
      command: "codex app-server"
      thread_sandbox: "workspace-write"
    server:
      host: "127.0.0.1"
      port: 4000
    workflow:
      states:
        Refining:
          profile: refinement
        Ready:
          profile: implementation
        In Progress:
          profile: implementation
        Ready to Merge:
          profile: merge
        Merging:
          profile: merge
      human_review_states: ["Needs Refinement Review", "Needs Implementation Review"]
      allowed_transitions:
        - {from: Ready, to: In Progress, actor: codex, profile: implementation}
      tool_policy:
        linear:
          exposed_tools: ["linear_task_read", "linear_task_update"]
          raw_graphql: false
    profiles:
      refinement:
        name: "Refinement"
        executor: {type: codex_agent}
        prompt: {mode: extend, template: "Refine the task."}
        allowed_updates: {description: true, comment: true, result: false, target_states: ["Needs Refinement Review"]}
      implementation:
        name: "Implementation"
        executor: {type: codex_agent}
        prompt: {mode: extend, template: "Implement the task."}
        allowed_updates: {description: false, comment: true, result: true, target_states: ["In Progress", "Needs Implementation Review"]}
      merge:
        name: "Merge"
        executor: {type: codex_agent}
        prompt: {mode: extend, template: "Merge the task."}
        allowed_updates: {description: false, comment: true, result: true, target_states: ["Merging", "Done"]}
    ---

    Imported workflow prompt.
    """
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
