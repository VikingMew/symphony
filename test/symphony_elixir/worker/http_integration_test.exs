defmodule SymphonyElixir.Worker.HttpIntegrationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Worker.{Client, Config, Executor}

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
      payload: execution(source, revision)
    }

    lease = %{id: "lease-1", expires_at: DateTime.add(DateTime.utc_now(), 60, :second)}
    start_supervised!({Persistence, %{task: task, lease: lease}})
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
    assert {:ok, %{"task" => nil}} = Client.claim(config, Map.put(identity, "available_slots", 1))
    assert {:ok, heartbeat} = Client.heartbeat(config, identity, %{"active_leases" => [claim["lease_id"]]})
    assert heartbeat["lease_renewals"] == ["lease-1"]

    result = Executor.execute(config, claim)
    assert result.status == :completed
    assert result.codex.session_id == "codex-session-1"
    assert result.validation.overall_status == :passed

    assert {:ok, %{"accepted" => true}} = Client.event(config, identity, claim["task_id"], "task.completed", result)
    assert {:ok, %{"accepted" => true}} = Client.event(config, identity, claim["task_id"], "task.completed", result)
    assert [first, second] = Persistence.events()
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
      request_options: [plug: SymphonyElixirWeb.Endpoint]
    }
  end

  defp execution(source, revision) do
    %{
      "version" => 1,
      "repository" => source,
      "revision" => revision,
      "branch" => "vikingmew-sym-12",
      "hooks" => [%{"command" => "git rev-parse HEAD", "timeout_seconds" => 10}],
      "codex" => %{"command" => "printf 'SYMPHONY_CODEX_SESSION_ID=codex-session-1\\n'", "timeout_seconds" => 10},
      "required_gates" => [%{"command" => "git status --porcelain", "timeout_seconds" => 10}],
      "handoff" => %{"command" => "git rev-parse HEAD", "timeout_seconds" => 10}
    }
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
