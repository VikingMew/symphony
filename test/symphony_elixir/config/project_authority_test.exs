defmodule SymphonyElixir.Config.ProjectAuthorityTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.ProjectAuthority

  @project %{
    id: "project-id",
    slug: "project-slug",
    linear_project_slug: "linear-project",
    repository_url: "git@github.com:org/repo.git",
    default_branch: "main",
    checkout_depth: 1,
    source_strategy: "clone",
    worktree_fetch: true,
    worktree_cleanup: false
  }

  test "diagnostics classify clean duplicates and conflicts for every project-owned field" do
    carrier = %{
      "tracker" => %{"project_slug" => "linear-project"},
      "project" => %{
        "repository_url" => "git@github.com:org/other.git",
        "default_branch" => " main ",
        "checkout_depth" => "1",
        "source_strategy" => "worktree",
        "worktree_fetch" => "true"
      }
    }

    diagnostics = ProjectAuthority.diagnostics(@project, carrier)

    assert Enum.map(diagnostics, &{&1.path, &1.status}) == [
             {"tracker.project_slug", :legacy_duplicate},
             {"project.repository_url", :conflict},
             {"project.default_branch", :legacy_duplicate},
             {"project.checkout_depth", :legacy_duplicate},
             {"project.source_strategy", :conflict},
             {"project.worktree_fetch", :legacy_duplicate},
             {"project.worktree_cleanup", :clean}
           ]

    assert ProjectAuthority.conflicts(@project, carrier) == [
             %{
               path: "project.repository_url",
               installed_value: "git@github.com:org/repo.git",
               package_value: "git@github.com:org/other.git"
             },
             %{
               path: "project.source_strategy",
               installed_value: "clone",
               package_value: "worktree"
             }
           ]
  end

  test "strip removes all carriers and inject materializes project authority" do
    durable = %{
      "tracker" => %{"kind" => "linear", "project_slug" => "legacy"},
      "project" => %{
        "repository_url" => "legacy",
        "default_branch" => "legacy",
        "checkout_depth" => 7,
        "source_strategy" => "worktree",
        "worktree_fetch" => false,
        "worktree_cleanup" => true,
        "setup_commands" => ["mix setup"]
      }
    }

    stripped = ProjectAuthority.strip(durable)

    assert stripped == %{
             "tracker" => %{"kind" => "linear"},
             "project" => %{"setup_commands" => ["mix setup"]}
           }

    injected = ProjectAuthority.inject(stripped, @project)
    assert get_in(injected, ["tracker", "project_slug"]) == "linear-project"
    assert get_in(injected, ["project", "repository_url"]) == "git@github.com:org/repo.git"
    assert get_in(injected, ["project", "worktree_cleanup"]) == false
  end

  test "inherit missing keeps explicit package values and fills omitted carriers" do
    source = ProjectAuthority.inject(%{}, @project)

    inherited =
      ProjectAuthority.inherit_missing(
        %{"project" => %{"repository_url" => "git@github.com:org/package.git"}},
        source
      )

    assert get_in(inherited, ["project", "repository_url"]) == "git@github.com:org/package.git"
    assert get_in(inherited, ["tracker", "project_slug"]) == "linear-project"
    assert get_in(inherited, ["project", "checkout_depth"]) == 1
    assert get_in(inherited, ["project", "worktree_cleanup"]) == false
  end

  test "de-identified five-row legacy fixture always resolves from project authority" do
    carriers = [
      ProjectAuthority.inject(%{}, @project),
      %{"tracker" => %{"project_slug" => "other"}},
      %{"project" => %{"repository_url" => "git@github.com:org/legacy.git"}},
      %{"project" => %{"checkout_depth" => 1, "worktree_fetch" => false}},
      %{}
    ]

    statuses = Enum.map(carriers, &Enum.map(ProjectAuthority.diagnostics(@project, &1), fn item -> item.status end))

    assert Enum.at(statuses, 0) == List.duplicate(:legacy_duplicate, 7)
    assert :conflict in Enum.at(statuses, 1)
    assert :conflict in Enum.at(statuses, 2)
    assert Enum.at(statuses, 3) |> Enum.count(&(&1 == :conflict)) == 1
    assert Enum.at(statuses, 4) == List.duplicate(:clean, 7)

    Enum.each(carriers, fn carrier ->
      resolved = ProjectAuthority.inject(ProjectAuthority.strip(carrier), @project)
      assert get_in(resolved, ["tracker", "project_slug"]) == @project.linear_project_slug
      assert get_in(resolved, ["project", "repository_url"]) == @project.repository_url
      assert get_in(resolved, ["project", "worktree_fetch"]) == @project.worktree_fetch
    end)
  end

  test "drift warnings include project identity field path and status" do
    log =
      capture_log(fn ->
        assert :ok =
                 ProjectAuthority.warn_drift(@project, %{
                   "project" => %{"repository_url" => "git@github.com:org/legacy.git"}
                 })
      end)

    assert log =~ "project_authority_drift"
    assert log =~ "project_id=project-id"
    assert log =~ "project_slug=project-slug"
    assert log =~ "field_path=project.repository_url"
    assert log =~ "status=conflict"
  end
end
