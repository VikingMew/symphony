defmodule SymphonyElixir.Worker.HttpIntegrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Worker.{Client, Config, Executor}

  defmodule WorkerApiSurface do
    use Plug.Router

    alias SymphonyElixirWeb.WorkerApiController

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/api/worker/v1/register" do
      WorkerApiController.register(conn, conn.body_params)
    end

    post "/api/worker/v1/tasks/claim" do
      WorkerApiController.claim(conn, conn.body_params)
    end

    post "/api/worker/v1/heartbeat" do
      WorkerApiController.heartbeat(conn, conn.body_params)
    end

    post "/api/worker/v1/tasks/:task_id/events" do
      WorkerApiController.task_event(conn, Map.put(conn.body_params, "task_id", task_id))
    end
  end

  defmodule Persistence do
    use Agent

    def child_spec(claim), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [claim]}}
    def start_link(claim), do: Agent.start_link(fn -> %{claim: claim, claimed?: false, events: []} end, name: __MODULE__)
    def worker_protocol_version, do: "worker-api-v1"
    def worker_heartbeat_interval_seconds, do: 1
    def worker_lease_duration_seconds, do: 60
    def valid_worker_registration_token?(token), do: token == "integration-token"

    def register_worker(_attrs) do
      {:ok, %{worker: %{id: "worker-1"}, session: %{id: "session-1"}}}
    end

    def claim_task(_worker_id, _session_id, _params) do
      Agent.get_and_update(__MODULE__, fn
        %{claimed?: false, claim: claim} = state -> {{:ok, claim}, %{state | claimed?: true}}
        state -> {{:ok, nil}, state}
      end)
    end

    def heartbeat(_worker_id, _session_id, params) do
      {:ok, %{ok: true, lease_renewals: params["active_leases"], commands: []}}
    end

    def record_worker_task_event(_worker_id, _session_id, task_id, event_type, payload) do
      Agent.update(__MODULE__, &update_in(&1.events, fn events -> [{task_id, event_type, payload} | events] end))
      {:ok, %{id: "event-#{length(events())}"}}
    end

    def events, do: Agent.get(__MODULE__, &Enum.reverse(&1.events))
  end

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    previous_worker_api = Application.get_env(:symphony_elixir, :worker_api)
    root = Path.join(File.cwd!(), ".worker-integration-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    git!(source, ["init", "--initial-branch=main"])
    git!(source, ["config", "user.email", "worker@example.test"])
    git!(source, ["config", "user.name", "Worker Test"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])
    git!(source, ["commit", "-m", "fixture"])
    revision = git!(source, ["rev-parse", "HEAD"])

    task = %{
      id: "task-1",
      project_id: "project-1",
      run_id: "run-1",
      issue_identifier: "SYM-12",
      payload: panel_payload(source, revision)
    }

    lease = %{id: "lease-1", attempt: 1, expires_at: DateTime.add(DateTime.utc_now(), 60, :second)}

    correlation = %{
      "issue_id" => "issue-1",
      "run_attempt" => 0,
      "worker_session_id" => "session-1"
    }

    start_supervised!({Persistence, %{task: task, lease: lease, correlation: correlation}})
    Application.put_env(:symphony_elixir, :persistence_module, Persistence)
    Application.put_env(:symphony_elixir, :worker_api, registration_token: "integration-token")

    on_exit(fn ->
      restore_env(:persistence_module, previous_persistence)
      restore_env(:worker_api, previous_worker_api)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "runs register through terminal event over the real worker HTTP surface", %{root: root} do
    config = config(root)
    assert {:ok, registration} = Client.register(config)

    identity = %{
      "worker_id" => registration["worker_id"],
      "session_id" => registration["session_id"],
      "protocol_version" => Client.protocol_version()
    }

    assert {:ok, claim} = Client.claim(config, Map.put(identity, "available_slots", 1))
    assert claim["task_id"] == "task-1"
    assert claim["issue_id"] == "issue-1"
    assert claim["run_attempt"] == 0
    assert claim["lease_attempt"] == 1
    assert claim["worker_session_id"] == "session-1"
    assert {:ok, %{"task" => nil}} = Client.claim(config, Map.put(identity, "available_slots", 1))
    assert {:ok, heartbeat} = Client.heartbeat(config, identity, %{"active_leases" => [claim["lease_id"]]})
    assert heartbeat["lease_renewals"] == ["lease-1"]

    assert {:ok, %{"accepted" => true}} =
             Client.event(config, identity, claim["task_id"], "task.progress", %{phase: "execution_started"})

    result = Executor.execute(config, claim)
    assert result.status == :completed
    assert result.codex.session_id == "codex-session-1"
    assert result.validation.overall_status == :passed
    assert result.handoff.commit == "fixture-commit"
    assert result.handoff.pr == "PR-12"

    assert {:ok, %{"accepted" => true}} = Client.event(config, identity, claim["task_id"], "task.completed", result)
    assert {:ok, %{"accepted" => true}} = Client.event(config, identity, claim["task_id"], "task.completed", result)
    assert [{"task-1", "task.progress", %{"phase" => "execution_started"}}, first, second] = Persistence.events()
    assert {"task-1", "task.completed", payload} = first
    assert {"task-1", "task.completed", ^payload} = second
    assert payload["codex"]["session_id"] == "codex-session-1"
    refute inspect(payload) =~ "workflow_version_id"
  end

  defp config(root) do
    %Config{
      panel_url: "http://panel.test",
      registration_token: "integration-token",
      worker_name: "integration-worker",
      workspace_root: Path.join(root, "workspaces"),
      cache_root: Path.join(root, "cache"),
      log_root: Path.join(root, "logs"),
      image_reference: "symphony-worker:test",
      source_revision: "worker-revision",
      request_options: [plug: WorkerApiSurface]
    }
  end

  defp panel_payload(source, revision) do
    %{
      "issue" => %{"identifier" => "SYM-12", "title" => "Integration test", "description" => "Run the fixture."},
      "prompt" => "Complete the task.",
      "workflow_profile" => "implementation",
      "execution_mode" => "worker",
      "repository" => %{
        "url" => source,
        "source_ref" => revision,
        "implementation_branch" => "vikingmew-sym-12"
      },
      "hooks" => %{
        "after_create" => "git rev-parse HEAD",
        "before_run" => nil,
        "after_run" => nil,
        "before_remove" => nil,
        "timeout_ms" => 10_000
      },
      "codex" => %{"command" => "printf 'SYMPHONY_CODEX_SESSION_ID=codex-session-1\\n'"},
      "limits" => %{"turn_timeout_ms" => 10_000},
      "required_gates" => [%{"name" => "clean", "command" => "git status --porcelain", "timeout_ms" => 10_000}],
      "handoff" => %{
        "command" => "printf 'SYMPHONY_HANDOFF_COMMIT=fixture-commit\\nSYMPHONY_HANDOFF_PR=PR-12\\n'",
        "timeout_seconds" => 10
      }
    }
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
