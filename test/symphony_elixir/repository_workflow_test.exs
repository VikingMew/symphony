defmodule SymphonyElixir.RepositoryWorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RepositoryWorkflow

  @workflow File.read!("docs/examples/workflow.yml")
  @profiles File.read!("docs/examples/profiles.yml")

  test "sync validates first and is idempotent" do
    parent = self()
    project = %{slug: "alpha", enabled: true}
    {:ok, state} = Agent.start_link(fn -> nil end)
    deps = deps(parent, state, [project])

    assert {:ok, %{changed: 1, unchanged: 0}} = RepositoryWorkflow.sync("alpha", "/package", deps)
    assert_received {:import, ^project, raw, "repository_workflow_package"}
    Agent.update(state, fn _ -> %{raw_workflow_md: raw, source: "repository_workflow_package"} end)

    assert {:ok, %{changed: 0, unchanged: 1}} = RepositoryWorkflow.sync("alpha", "/package", deps)
    refute_received {:import, _, _, _}
    assert :ok = RepositoryWorkflow.check("alpha", "/package", deps)
  end

  test "check reports enabled projects whose snapshots drift" do
    projects = [%{slug: "alpha", enabled: true}, %{slug: "disabled", enabled: false}]
    {:ok, state} = Agent.start_link(fn -> %{raw_workflow_md: "old", source: "manual"} end)

    assert {:error, {:workflow_drift, ["alpha"]}} =
             RepositoryWorkflow.check(:all, "/package", deps(self(), state, projects))
  end

  test "invalid package does not write" do
    parent = self()
    {:ok, state} = Agent.start_link(fn -> nil end)
    deps = deps(parent, state, [%{slug: "alpha", enabled: true}])
    deps = put_in(deps.read_file, fn _path -> {:ok, "invalid: ["} end)

    assert {:error, _reason} = RepositoryWorkflow.sync(:all, "/package", deps)
    refute_received {:import, _, _, _}
  end

  defp deps(parent, state, projects) do
    %{
      list_projects: fn -> projects end,
      current_workflow: fn _project -> Agent.get(state, & &1) end,
      import_workflow: fn project, raw, source ->
        send(parent, {:import, project, raw, source})
        {:ok, %{}}
      end,
      read_file: fn
        "/package/workflow.yml" -> {:ok, @workflow}
        "/package/profiles.yml" -> {:ok, @profiles}
      end
    }
  end
end
