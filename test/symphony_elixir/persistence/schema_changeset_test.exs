defmodule SymphonyElixir.Persistence.SchemaChangesetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ExecutionRequirement
  alias SymphonyElixir.Persistence.{IssueRecord, RunRecord, Worker, WorkerSession, WorkflowRecord, WorkspaceRecord}

  test "workflow changeset accepts the canonical empty project prompt" do
    attrs = %{
      project_id: Ecto.UUID.generate(),
      raw_workflow_md: "---\ntracker:\n  kind: linear\n---\n",
      yaml_config: %{"tracker" => %{"kind" => "linear"}},
      prompt_body: "",
      source: "web_project_settings"
    }

    assert WorkflowRecord.changeset(%WorkflowRecord{}, attrs).valid?
    assert WorkflowRecord.changeset(%WorkflowRecord{}, Map.put(attrs, :prompt_body, nil)).valid? == false
  end

  test "issue schema and changeset omit the Linear state mirror" do
    assert :state not in IssueRecord.__schema__(:fields)

    changeset =
      IssueRecord.changeset(%IssueRecord{}, %{
        identifier: "SYM-139",
        state: "Ready",
        snapshot: %{"state" => "In Progress"}
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :snapshot) == %{"state" => "In Progress"}
    assert Map.has_key?(changeset.changes, :state) == false
  end

  test "run changeset validates issue and operator run contracts" do
    valid_issue = %{
      kind: "issue",
      issue_identifier: "CCR-1",
      status: "running",
      execution_mode: "centralized"
    }

    assert RunRecord.changeset(%RunRecord{}, valid_issue).valid?
    assert RunRecord.changeset(%RunRecord{}, %{kind: "nap", status: "running", execution_mode: "centralized"}).valid?

    assert RunRecord.changeset(%RunRecord{}, %{kind: "issue", status: "running"}).valid? == false
    assert RunRecord.changeset(%RunRecord{}, %{kind: "other", status: "running"}).valid? == false

    remote_issue = %{
      kind: "issue",
      issue_identifier: "CCR-1",
      status: "running",
      execution_mode: "remote"
    }

    assert RunRecord.changeset(%RunRecord{}, remote_issue).valid? == false
  end

  test "host-probe session and run changesets require immutable correlation evidence" do
    now = DateTime.utc_now()
    worker_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    capabilities = ["gui-session"]

    session_attrs = %{
      worker_id: worker_id,
      protocol_version: "worker-api-v1",
      total_slots: 1,
      execution_surface: "host_probe",
      probe_id: "local-host",
      capabilities: %{"values" => capabilities},
      capability_digest: ExecutionRequirement.capability_digest(capabilities),
      heartbeat_interval_seconds: 5,
      lease_duration_seconds: 30,
      connected_at: now,
      status: "online"
    }

    assert WorkerSession.changeset(%WorkerSession{}, session_attrs).valid?
    refute WorkerSession.changeset(%WorkerSession{}, Map.put(session_attrs, :total_slots, 2)).valid?
    refute WorkerSession.changeset(%WorkerSession{}, Map.put(session_attrs, :capability_digest, "changed")).valid?

    run_attrs = %{
      kind: "issue",
      issue_identifier: "SYM-175",
      status: "running",
      execution_mode: "worker",
      execution_requirement: "host_only",
      execution_surface: "host_probe",
      probe_id: "local-host",
      worker_session_id: session_id
    }

    assert RunRecord.changeset(%RunRecord{}, run_attrs).valid?
    refute RunRecord.changeset(%RunRecord{}, Map.delete(run_attrs, :worker_session_id)).valid?
    refute RunRecord.changeset(%RunRecord{}, Map.put(run_attrs, :execution_requirement, "default")).valid?
  end

  test "run changeset enforces the terminal failure matrix and rejects historical unknown" do
    base = %{kind: "issue", issue_identifier: "CCR-1", execution_mode: "centralized"}

    assert RunRecord.changeset(%RunRecord{}, Map.merge(base, %{status: "completed"})).valid?

    refute RunRecord.changeset(
             %RunRecord{},
             Map.merge(base, %{status: "completed", failure_reason: "runtime_failure"})
           ).valid?

    Enum.each(["failed", "blocked", "cancelled", "stopped"], fn status ->
      attrs =
        Map.merge(base, %{
          status: status,
          failure_reason: "runtime_failure",
          failure_evidence: %{"reason" => "worker_error"}
        })

      assert RunRecord.changeset(%RunRecord{}, attrs).valid?
      refute RunRecord.changeset(%RunRecord{}, Map.delete(attrs, :failure_reason)).valid?
      refute RunRecord.changeset(%RunRecord{}, Map.put(attrs, :failure_evidence, %{})).valid?
      refute RunRecord.changeset(%RunRecord{}, Map.put(attrs, :failure_reason, "unknown")).valid?
    end)

    refute RunRecord.changeset(%RunRecord{}, Map.merge(base, %{status: "succeeded"})).valid?
  end

  test "worker changeset validates identity and lifecycle status" do
    assert Worker.changeset(%Worker{}, %{name: "worker-1", status: "online"}).valid?

    assert Worker.changeset(%Worker{}, %{status: "online"}).valid? == false
    assert Worker.changeset(%Worker{}, %{name: "worker-1", status: "busy"}).valid? == false
  end

  test "workspace changeset validates required workspace fields" do
    assert WorkspaceRecord.changeset(%WorkspaceRecord{}, %{issue_identifier: "CCR-1", path: "/tmp/CCR-1", status: "active"}).valid?

    assert WorkspaceRecord.changeset(%WorkspaceRecord{}, %{issue_identifier: "CCR-1", status: "active"}).valid? == false
    assert WorkspaceRecord.changeset(%WorkspaceRecord{}, %{path: "/tmp/CCR-1", status: "active"}).valid? == false
  end
end
