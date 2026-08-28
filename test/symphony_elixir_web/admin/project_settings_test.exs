defmodule SymphonyElixirWeb.Admin.ProjectSettingsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixirWeb.Admin.ProjectSettings

  test "builds project attrs from form params" do
    attrs =
      ProjectSettings.attrs(%{
        "name" => "Default",
        "slug" => "default",
        "linear_project_slug" => "  linear-project  ",
        "repository_url" => "",
        "default_branch" => "",
        "checkout_depth" => "3",
        "source_strategy" => "worktree",
        "worktree_fetch" => "true",
        "description" => "  ",
        "enabled" => "true"
      })

    assert attrs == %{
             name: "Default",
             slug: "default",
             linear_project_slug: "linear-project",
             repository_url: nil,
             default_branch: "main",
             checkout_depth: 3,
             source_strategy: "worktree",
             worktree_fetch: true,
             worktree_cleanup: true,
             description: nil,
             enabled: true
           }
  end

  test "detects project changes after normalizing blanks" do
    project = %{
      name: "Default",
      slug: "default",
      linear_project_slug: nil,
      repository_url: nil,
      default_branch: "main",
      checkout_depth: 1,
      source_strategy: "clone",
      worktree_fetch: true,
      worktree_cleanup: true,
      description: nil,
      enabled: false
    }

    refute ProjectSettings.changed?(project, Map.merge(ProjectSettings.attrs(%{"name" => "Default", "slug" => "default"}), %{linear_project_slug: "", repository_url: ""}))
    assert ProjectSettings.changed?(project, Map.merge(ProjectSettings.attrs(%{"name" => "Default", "slug" => "default"}), %{repository_url: "git@example.com:repo.git"}))
  end

  test "derives repository and worktree previews from shared roots" do
    form = %{
      "workspace_repository_base_root" => "/repos",
      "workspace_worktree_base_root" => "/worktrees"
    }

    project = %{repository_url: "git@github.com:owner/repo.git", default_branch: "main", enabled: true}

    assert ProjectSettings.repository_preview(form, [project]) =~ ~r|^/repos/repo-[a-f0-9]{12}$|
    assert ProjectSettings.worktree_preview(form) == "/worktrees/CCR-5"
  end

  test "derives empty-form previews from the schema workspace default" do
    workspace_root = get_in(Schema.defaults(), ["workspace", "root"])

    assert ProjectSettings.repository_preview(%{}, []) ==
             Path.join([workspace_root, "repositories", "project-<hash>"])

    assert ProjectSettings.worktree_preview(%{}) ==
             Path.join([workspace_root, "worktrees", "CCR-5"])
  end

  test "scopes configuration checklist items" do
    previous = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    try do
      items = ProjectSettings.configuration_missing_items(true, %{linear_project_slug: nil, repository_url: nil})

      assert [%{title: "Linear project slug"}, %{title: "Repository URL"}] =
               ProjectSettings.scoped_configuration_items(items, "Project")

      assert [%{title: "Current workflow"}] =
               ProjectSettings.scoped_configuration_items(items, "Workflow")

      assert [%{title: "Linear API token"}] =
               ProjectSettings.scoped_configuration_items(items, "Runtime")
    after
      if previous, do: System.put_env("LINEAR_API_KEY", previous), else: System.delete_env("LINEAR_API_KEY")
    end
  end

  test "applies project settings to workflow draft and formats team names" do
    project = %{
      linear_project_slug: "linear",
      repository_url: "git@example.com:repo.git",
      default_branch: "main",
      checkout_depth: 2,
      source_strategy: "worktree",
      worktree_fetch: false,
      worktree_cleanup: true,
      teams: [%{name: "Platform"}, %{name: "Infra"}]
    }

    draft = ProjectSettings.apply_to_workflow_draft(%{}, project)

    assert draft["tracker_project_slug"] == "linear"
    assert draft["project_checkout_depth"] == "2"
    assert draft["project_worktree_fetch"] == "false"
    assert ProjectSettings.team_names(project) == "Platform, Infra"
  end
end
