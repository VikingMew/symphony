defmodule SymphonyElixir.WorkflowStoreFakePersistenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Workflow, WorkflowStore}
  alias SymphonyElixir.Config.ProjectAuthority
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)

    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
    end)

    :ok
  end

  test "database source loads current workflow through fake persistence when file is missing" do
    raw =
      Workflow.load()
      |> then(fn {:ok, workflow} ->
        Workflow.to_markdown(
          workflow.config,
          String.replace(workflow.prompt, "You are an agent", "You are a fake database agent")
        )
      end)

    {:ok, project} = FakePersistence.default_project()
    assert {:ok, _version} = FakePersistence.import_package(project, raw, "test")

    missing_path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")
    Workflow.set_workflow_file_path(missing_path)

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{workflow: workflow, source: source}} = WorkflowStore.current_with_source()
    assert workflow.prompt =~ "fake database agent"
    assert source.type == :database
    assert Map.get(workflow, :setup_required, false) == false
  end

  test "database source reports no workflow when the database is empty even if local package exists" do
    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
    assert FakePersistence.current_workflow() == nil
  end

  test "database source keeps setup-required semantics at the Config boundary when files and workflow are missing" do
    missing_path = Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md")
    Workflow.set_workflow_file_path(missing_path)

    assert :ok = WorkflowStore.force_reload()

    assert {:ok, %{workflow: %{setup_required: true}, source: %{type: :setup_required}}} =
             WorkflowStore.current_with_source()

    assert {:ok, %{setup_required: true}} = WorkflowStore.current()
    assert {:error, :setup_required} = Config.settings()
  end

  test "matching portable project authority imports as a minimal workflow slice and exports from the project row" do
    {:ok, project} = FakePersistence.default_project()
    raw = matching_package(project, "Portable prompt")

    assert {:ok, %{project_workflow: workflow}} = FakePersistence.import_package(project, raw, "test")
    assert ProjectAuthority.diagnostics(project, workflow.yaml_config) |> Enum.all?(&(&1.status == :clean))

    assert {:ok, project_raw} = FakePersistence.export_workflow(workflow)
    assert {:ok, project_export} = Workflow.parse_content(project_raw)
    assert ProjectAuthority.carrier_values(project_export.config) == %{}

    assert {:ok, package_raw} = FakePersistence.export_package(FakePersistence.instance_workflow(), workflow)
    assert {:ok, package_export} = Workflow.parse_content(package_raw)
    assert get_in(package_export.config, ["tracker", "project_slug"]) == project.linear_project_slug
    assert get_in(package_export.config, ["project", "repository_url"]) == project.repository_url
    assert get_in(package_export.config, ["project", "worktree_cleanup"]) == project.worktree_cleanup
  end

  test "conflicting portable authority rejects before singleton workflow and snapshot writes" do
    {:ok, project} = FakePersistence.default_project()
    assert {:ok, _saved} = FakePersistence.import_package(project, matching_package(project, "Baseline"), "test")
    assert :ok = WorkflowStore.force_reload()

    baseline_instance = FakePersistence.instance_workflow()
    baseline_workflow = FakePersistence.current_workflow(project)
    baseline_snapshot = WorkflowStore.current_with_source()
    baseline_publications = FakePersistence.runtime_publication_count()

    conflicting =
      project
      |> matching_package("Rejected")
      |> String.replace(project.repository_url, "git@github.com:org/conflict.git")

    assert {:error,
            {:project_authority_conflict,
             [
               %{
                 path: "project.repository_url",
                 installed_value: "git@github.com:org/repo.git",
                 package_value: "git@github.com:org/conflict.git"
               }
             ]}} = FakePersistence.import_package(project, conflicting, "test")

    assert FakePersistence.instance_workflow() == baseline_instance
    assert FakePersistence.current_workflow(project) == baseline_workflow
    assert WorkflowStore.current_with_source() == baseline_snapshot
    assert FakePersistence.runtime_publication_count() == baseline_publications
  end

  defp matching_package(project, prompt) do
    {:ok, loaded} = Workflow.load()

    config =
      loaded.config
      |> put_in([Access.key("tracker", %{}), "project_slug"], project.linear_project_slug)
      |> put_in([Access.key("project", %{}), "repository_url"], project.repository_url)
      |> put_in([Access.key("project", %{}), "default_branch"], project.default_branch)
      |> put_in([Access.key("project", %{}), "checkout_depth"], project.checkout_depth)
      |> put_in([Access.key("project", %{}), "source_strategy"], project.source_strategy)
      |> put_in([Access.key("project", %{}), "worktree_fetch"], project.worktree_fetch)
      |> put_in([Access.key("project", %{}), "worktree_cleanup"], project.worktree_cleanup)

    Workflow.to_markdown(config, prompt)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
