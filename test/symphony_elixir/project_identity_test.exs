defmodule SymphonyElixir.ProjectIdentityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.ProjectIdentity
  alias SymphonyElixir.TestSupport.FakePersistence
  alias SymphonyElixir.Workflow

  test "package persistence replaces portable identity with the selected project identity" do
    {:ok, loaded} = Workflow.load_example_package()
    {:ok, project} = FakePersistence.default_project()

    config =
      loaded.config
      |> put_in(["tracker", "project_slug"], "portable-project")
      |> put_in(
        [Access.key("project", %{}), "repository_url"],
        "https://example.test/portable.git"
      )

    assert {:ok, %{project_workflow: workflow}} =
             FakePersistence.import_package(
               project,
               Workflow.to_markdown(config, loaded.prompt),
               "identity-test"
             )

    assert ProjectIdentity.matches?(workflow.yaml_config, project)
    assert ProjectIdentity.workflow_matches?(workflow, project)
  end

  test "status and explicit apply reconcile five rows atomically and idempotently" do
    {:ok, default_project} = FakePersistence.default_project()

    projects =
      [default_project] ++
        Enum.map(2..5, fn index ->
          {:ok, project} =
            FakePersistence.create_project(%{
              name: "Project #{index}",
              slug: "project-#{index}",
              linear_project_slug: "linear-#{index}",
              repository_url: "https://example.test/project-#{index}.git",
              default_branch: "main",
              enabled: true
            })

          project
        end)

    {:ok, _instance} =
      FakePersistence.put_instance_workflow(
        %{"workspace" => %{"root" => "/preserved/workspaces"}},
        "Preserved prompt"
      )

    Enum.each(projects, &put_contaminated_workflow!/1)

    projects_before = FakePersistence.list_projects()
    instance_before = FakePersistence.instance_workflow()

    assert {:ok, %{mismatch_count: 5}} = FakePersistence.project_identity_status()

    FakePersistence.fail_next_project_identity_reconciliation!(:write_failed)
    assert FakePersistence.reconcile_project_identities() == {:error, :write_failed}
    assert {:ok, %{mismatch_count: 5}} = FakePersistence.project_identity_status()

    assert {:ok, %{updated: 5, status: %{mismatch_count: 0}}} =
             FakePersistence.reconcile_project_identities()

    assert {:ok, %{updated: 0, status: %{mismatch_count: 0}}} =
             FakePersistence.reconcile_project_identities()

    assert FakePersistence.list_projects() == projects_before
    assert FakePersistence.instance_workflow() == instance_before

    Enum.each(projects, fn project ->
      workflow = FakePersistence.current_workflow(project)
      assert workflow.source == "contaminated-fixture"
      assert get_in(workflow.yaml_config, ["tracker", "active_states"]) == ["Ready"]
      assert get_in(workflow.yaml_config, ["project", "default_branch"]) == "main"

      {:ok, raw} = Workflow.parse_content(workflow.raw_workflow_md)
      assert get_in(raw.config, ["tracker", "active_states"]) == ["Todo"]
      assert get_in(raw.config, ["project", "default_branch"]) == "main"
      assert ProjectIdentity.workflow_matches?(workflow, project)
    end)
  end

  defp put_contaminated_workflow!(project) do
    config = %{
      "tracker" => %{"kind" => "linear", "project_slug" => "example-project", "active_states" => ["Ready"]},
      "project" => %{
        "repository_url" => "https://example.test/example.git",
        "default_branch" => "main"
      }
    }

    raw_config = put_in(config, ["tracker", "active_states"], ["Todo"])

    FakePersistence.put_workflow(%{
      id: "workflow-#{project.id}",
      project_id: project.id,
      source: "contaminated-fixture",
      yaml_config: config,
      raw_workflow_md: Workflow.to_markdown(raw_config, ""),
      prompt_body: ""
    })
  end
end
