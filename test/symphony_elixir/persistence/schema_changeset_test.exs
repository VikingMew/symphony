defmodule SymphonyElixir.Persistence.SchemaChangesetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Persistence.{RunRecord, TaskRecord, Worker, WorkspaceRecord}

  test "run changeset validates issue and operator run contracts" do
    assert RunRecord.changeset(%RunRecord{}, %{kind: "issue", issue_identifier: "CCR-1", status: "running", execution_mode: "centralized"}).valid?
    assert RunRecord.changeset(%RunRecord{}, %{kind: "nap", status: "running", execution_mode: "centralized"}).valid?

    refute RunRecord.changeset(%RunRecord{}, %{kind: "issue", status: "running"}).valid?
    refute RunRecord.changeset(%RunRecord{}, %{kind: "other", status: "running"}).valid?
    refute RunRecord.changeset(%RunRecord{}, %{kind: "issue", issue_identifier: "CCR-1", status: "running", execution_mode: "remote"}).valid?
  end

  test "task changeset validates status execution mode and queued time" do
    now = DateTime.utc_now()

    assert TaskRecord.changeset(%TaskRecord{}, %{status: "queued", priority: 10, execution_mode: "worker", queued_at: now}).valid?

    refute TaskRecord.changeset(%TaskRecord{}, %{status: "unknown", priority: 10, execution_mode: "worker", queued_at: now}).valid?
    refute TaskRecord.changeset(%TaskRecord{}, %{status: "queued", priority: 10, execution_mode: "remote", queued_at: now}).valid?
    refute TaskRecord.changeset(%TaskRecord{}, %{status: "queued", execution_mode: "worker"}).valid?
  end

  test "worker changeset validates identity and lifecycle status" do
    assert Worker.changeset(%Worker{}, %{name: "worker-1", status: "online"}).valid?

    refute Worker.changeset(%Worker{}, %{status: "online"}).valid?
    refute Worker.changeset(%Worker{}, %{name: "worker-1", status: "busy"}).valid?
  end

  test "workspace changeset validates required workspace fields" do
    assert WorkspaceRecord.changeset(%WorkspaceRecord{}, %{issue_identifier: "CCR-1", path: "/tmp/CCR-1", status: "active"}).valid?

    refute WorkspaceRecord.changeset(%WorkspaceRecord{}, %{issue_identifier: "CCR-1", status: "active"}).valid?
    refute WorkspaceRecord.changeset(%WorkspaceRecord{}, %{path: "/tmp/CCR-1", status: "active"}).valid?
  end
end
