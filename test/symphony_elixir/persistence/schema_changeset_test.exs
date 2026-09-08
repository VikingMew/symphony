defmodule SymphonyElixir.Persistence.SchemaChangesetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Persistence.{RunRecord, Worker, WorkspaceRecord}

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
