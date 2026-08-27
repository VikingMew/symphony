defmodule SymphonyElixir.Persistence.ProjectTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Persistence, Repo}

  test "delete_project returns repo unavailable when persistence is stopped" do
    refute Process.whereis(Repo)
    assert Persistence.delete_project("project-id") == {:error, :repo_unavailable}
  end

  test "create_run requires an explicit project_id" do
    assert Persistence.create_run(%{}) == {:error, :project_id_required}
    assert Persistence.create_run(%{project_id: ""}) == {:error, :project_id_required}
  end

  test "upsert_issue requires an explicit project_id" do
    assert Persistence.upsert_issue(%{identifier: "MT-NO-PROJECT"}) == {:error, :project_id_required}
  end
end
