defmodule SymphonyElixir.HostProbeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config, Config.Schema, ExecutionRequirement, RoutingProjection}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Persistence.WorkerRegistry

  test "normalizes host-only and capability labels and enforces the routing matrix" do
    assert ExecutionRequirement.from_labels([" execution:HOST-only ", "capability:gui-session", "capability:manual-pr-handoff"]) == %{
             execution_requirement: "host_only",
             required_capabilities: ["gui-session", "manual-pr-handoff"]
           }

    unmarked = host_probe_issue([])
    host_only = host_probe_issue(["execution:host-only"])
    gui = host_probe_issue(["execution:host-only", "capability:gui-session"])
    container = session("container_worker", [])
    host = session("host_probe", [])

    assert :ok = ExecutionRequirement.admit(unmarked, container)
    assert {:skip, :host_only_surface_required} = ExecutionRequirement.admit(host_only, container)
    assert {:skip, :host_probe_requires_host_only} = ExecutionRequirement.admit(unmarked, host)
    assert :ok = ExecutionRequirement.admit(host_only, host)
    assert {:skip, :required_capabilities_unavailable} = ExecutionRequirement.admit(gui, host)
    assert :ok = ExecutionRequirement.admit(gui, session("host_probe", ["gui-session"]))
  end

  test "projects both waiting reasons, the exact threshold, and recovery" do
    issue = host_probe_issue(["execution:host-only", "capability:gui-session"])
    started_at = ~U[2026-11-10 05:00:00Z]

    offline = RoutingProjection.build_issue_projection(issue, [], started_at)
    assert offline["routing_status"] == "waiting_for_probe"
    assert offline["routing_reason"] == "no_online_eligible_probe"
    assert offline["eligible_probe_count"] == 0
    refute RoutingProjection.alert?(offline, DateTime.add(started_at, 29, :second))
    assert RoutingProjection.alert?(offline, DateTime.add(started_at, 30, :second))

    mismatch = RoutingProjection.build_issue_projection(issue, [session("host_probe", [])], DateTime.add(started_at, 10, :second))
    assert mismatch["routing_reason"] == "capability_mismatch"
    assert mismatch["routing_since_at"] != offline["routing_since_at"]
    assert RoutingProjection.preserve_wait_since(offline, mismatch) == mismatch

    repeated = RoutingProjection.build_issue_projection(issue, [], DateTime.add(started_at, 20, :second))
    assert RoutingProjection.preserve_wait_since(offline, repeated)["routing_since_at"] == offline["routing_since_at"]

    ready =
      RoutingProjection.build_issue_projection(
        issue,
        [session("host_probe", ["gui-session"])],
        DateTime.add(started_at, 30, :second)
      )

    assert ready["routing_status"] == "ready_host_probe"
    assert ready["routing_reason"] == nil
    assert ready["eligible_probe_count"] == 1
    assert ready["routing_since_at"] == nil
  end

  test "waiting_for_probe is only a routing status" do
    workflow_policy = Schema.default_workflow_policy()
    states = workflow_policy["states"] || workflow_policy[:states]

    refute Map.has_key?(states, "waiting_for_probe")

    source = File.read!("lib/symphony_elixir/execution_requirement.ex")
    assert source =~ ~s({"host_only", _surface, _matches} -> {:skip, :host_only_surface_required})
    refute source =~ "container_fallback"
  end

  test "freezes one stable allowlisted capability digest and fixed installation policy" do
    assert {:ok, capabilities} =
             ExecutionRequirement.normalize_capabilities(%{
               "values" => ["manual-pr-handoff", "gui-session", "gui-session"]
             })

    assert capabilities == ["gui-session", "manual-pr-handoff"]

    assert ExecutionRequirement.capability_digest(capabilities) ==
             ExecutionRequirement.capability_digest(Enum.reverse(capabilities))

    assert {:error, :invalid_host_probe_capabilities} =
             ExecutionRequirement.normalize_capabilities(["shell"])

    assert {:ok, settings} = Schema.parse(%{})

    assert %{
             enabled: false,
             heartbeat_interval_seconds: 5,
             lease_duration_seconds: 30,
             local_deadline_seconds: 30
           } = settings.host_probe

    workflow = %{setup_required: false, config: %{"host_probe" => %{"enabled" => true, "auth_token" => "secret"}}}

    assert %{enabled: true, auth_token: "secret", local_deadline_seconds: 30} =
             Config.with_workflow_context(workflow, &Config.host_probe_policy/0)

    assert {:error, {:invalid_workflow_config, blank_message}} =
             Schema.parse(%{"host_probe" => %{"enabled" => true, "auth_token" => ""}})

    assert blank_message =~ "auth_token"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "host_probe" => %{
                 "enabled" => true,
                 "auth_token" => "secret",
                 "heartbeat_interval_seconds" => 10
               }
             })

    assert message =~ "heartbeat_interval_seconds"
  end

  test "worker registry accepts only the fixed host-probe registration shape" do
    registration = %{
      "execution_surface" => "host_probe",
      "probe_id" => "local-host",
      "worker_name" => "local-host",
      "protocol_version" => "worker-api-v1",
      "total_slots" => 1,
      "capabilities" => %{"values" => ["gui-session"]}
    }

    assert {:error, :host_probe_disabled} =
             Config.with_workflow_context(%{setup_required: false, config: %{}}, fn ->
               WorkerRegistry.register_worker(registration)
             end)

    workflow = %{setup_required: false, config: %{"host_probe" => %{"enabled" => true, "auth_token" => "secret"}}}

    Config.with_workflow_context(workflow, fn ->
      assert {:error, :invalid_host_probe_id} =
               registration |> Map.put("probe_id", "other") |> WorkerRegistry.register_worker()

      assert {:error, :invalid_total_slots} =
               registration |> Map.put("total_slots", 2) |> WorkerRegistry.register_worker()

      assert {:error, :invalid_host_probe_capabilities} =
               registration
               |> Map.put("capabilities", %{"values" => ["shell"]})
               |> WorkerRegistry.register_worker()

      assert {:error, :repo_unavailable} = WorkerRegistry.register_worker(registration)
    end)
  end

  defp host_probe_issue(labels),
    do: %Issue{id: "issue", identifier: "SYM-175", title: "Host probe", state: "Ready", blocked_by: [], labels: labels}

  defp session(surface, capabilities),
    do: %{execution_surface: surface, capabilities: %{"values" => capabilities}}
end
