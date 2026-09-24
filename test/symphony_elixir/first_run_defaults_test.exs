defmodule SymphonyElixir.FirstRunDefaultsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FirstRunDefaults

  @workflow_yaml """
  tracker:
    project_slug: example-project
    active_states: [Ready]
    terminal_states: [Done]
  project:
    repository_url: https://github.com/example/project
  workspace:
    root: /host/example/workspaces
  workflow:
    states:
      Ready:
        profile: implementation
        phase: implementation
        actor: codex
      Done:
        phase: done
        actor: human
    allowed_transitions:
      - from: Ready
        to: Done
        actor: codex
  """

  @profiles_yaml """
  base_prompt: |
    Default imported base prompt.
  profiles:
    implementation:
      name: Implementation
      executor: codex_agent
      prompt_mode: extend
      prompt_template: |
        Implement the task.
      allowed_updates:
        description: false
        comment: true
        result: true
      allowed_target_states:
        - Done
  """

  test "imports checked-in defaults when first-run prompt is accepted" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent))

    assert_received {:prompt, prompt}
    assert prompt =~ "1) Alpha (alpha)"
    assert prompt =~ "2) Beta (beta)"
    assert_received {:import_package, %{id: "project-beta"}, raw, "first_run_default_yaml"}
    assert raw =~ "tracker:"
    assert raw =~ "Default imported base prompt."
    assert raw =~ "implementation"
    assert raw =~ System.tmp_dir!() <> "/symphony_workspaces"
    assert raw =~ "/host/example/workspaces" == false
  end

  test "existing singleton workspace root survives first-run project import" do
    parent = self()

    assert :ok =
             FirstRunDefaults.maybe_import(
               [],
               deps(parent,
                 instance_workflow: fn ->
                   %{config: %{"workspace" => %{"root" => "/existing/workspaces"}}}
                 end
               )
             )

    assert_received {:import_package, %{id: "project-beta"}, raw, "first_run_default_yaml"}
    assert raw =~ "/existing/workspaces"
    assert raw =~ "/host/example/workspaces" == false
  end

  test "declining first-run prompt leaves database unchanged" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, prompt: fn _prompt -> "no\n" end))
    refute_received {:import_package, _, _, _}
  end

  test "opt-out flag skips prompt and import" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([no_default_yaml_prompt: true], deps(parent))
    refute_received {:prompt, _}
    refute_received {:import_package, _, _, _}
  end

  test "existing workflow skips default package reads" do
    parent = self()

    deps =
      deps(parent,
        instance_workflow: fn -> %{config: %{}} end,
        current_workflow: fn -> %{id: "current"} end,
        read_file: fn path ->
          send(parent, {:unexpected_read, path})
          {:error, :enoent}
        end
      )

    assert :ok = FirstRunDefaults.maybe_import([], deps)
    refute_received {:unexpected_read, _}
  end

  test "missing project context still allows first-run default import flow" do
    parent = self()

    assert :ok =
             FirstRunDefaults.maybe_import(
               [],
               deps(parent, current_workflow: fn -> {:error, :missing_project_context} end)
             )

    assert_received {:prompt, prompt}
    assert prompt =~ "1) Alpha (alpha)"
    assert_received {:import_package, %{id: "project-beta"}, raw, "first_run_default_yaml"}
    assert raw =~ "Default imported base prompt."
  end

  test "missing singleton imports both scopes even when a project workflow exists" do
    parent = self()

    assert :ok =
             FirstRunDefaults.maybe_import(
               [],
               deps(parent, current_workflow: fn -> %{id: "legacy-project-workflow"} end)
             )

    assert_received {:import_package, %{id: "project-beta"}, _raw, "first_run_default_yaml"}
  end

  test "missing project workflow imports both scopes even when singleton exists" do
    parent = self()

    assert :ok =
             FirstRunDefaults.maybe_import(
               [],
               deps(parent,
                 instance_workflow: fn -> %{config: %{}} end,
                 current_workflow: fn -> nil end
               )
             )

    assert_received {:import_package, %{id: "project-beta"}, _raw, "first_run_default_yaml"}
  end

  test "missing package file does not crash or import partial defaults" do
    parent = self()

    deps =
      deps(parent,
        read_file: fn
          path when is_binary(path) ->
            if String.ends_with?(path, "workflow.yml"), do: {:ok, @workflow_yaml}, else: {:error, :enoent}
        end
      )

    assert :ok = FirstRunDefaults.maybe_import([], deps)
    refute_received {:import_package, _, _, _}
  end

  test "invalid defaults do not create a workflow" do
    parent = self()

    deps =
      deps(parent,
        read_file: fn
          path ->
            if String.ends_with?(path, "workflow.yml"), do: {:ok, "tracker: ["}, else: {:ok, @profiles_yaml}
        end
      )

    assert :ok = FirstRunDefaults.maybe_import([], deps)
    refute_received {:import_package, _, _, _}
  end

  test "non-interactive startup logs available defaults without prompting" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, interactive?: fn -> false end))
    refute_received {:prompt, _}
    refute_received {:import_package, _, _, _}
  end

  test "zero-project interactive startup remains setup-required" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, list_projects: fn -> [] end))
    refute_received {:prompt, _}
    refute_received {:import_package, _, _, _}
    assert_received {:log, :info, message}
    assert message =~ "No enabled projects"
  end

  test "disabled Default placeholder never becomes first-run authority" do
    parent = self()
    placeholder = %{id: "bootstrap-project", name: "Default", slug: "default", enabled: false}

    assert :ok =
             FirstRunDefaults.maybe_import(
               [],
               deps(parent, list_projects: fn -> [placeholder] end)
             )

    refute_received {:prompt, _}
    refute_received {:import_package, _, _, _}
    assert_received {:log, :info, message}
    assert message =~ "No enabled projects"
  end

  test "startup without enabled projects remains setup-required without prompting" do
    parent = self()

    disabled_project = %{id: "project-disabled", name: "Disabled", slug: "disabled", enabled: false}

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, list_projects: fn -> [disabled_project] end))
    refute_received {:prompt, _}
    refute_received {:import_package, _, _, _}
    assert_received {:log, :info, message}
    assert message =~ "No enabled projects"
  end

  defp deps(parent, overrides \\ []) do
    defaults = %{
      instance_workflow: fn -> nil end,
      current_workflow: fn -> nil end,
      list_projects: fn ->
        [
          %{id: "project-alpha", name: "Alpha", slug: "alpha", enabled: true},
          %{id: "project-disabled", name: "Disabled", slug: "disabled", enabled: false},
          %{id: "project-beta", name: "Beta", slug: "beta", enabled: true}
        ]
      end,
      import_package: fn project, raw, source ->
        send(parent, {:import_package, project, raw, source})
        {:ok, %{id: "workflow"}}
      end,
      package_root: fn -> "/package" end,
      read_file: fn
        "/package/workflow.yml" -> {:ok, @workflow_yaml}
        "/package/profiles.yml" -> {:ok, @profiles_yaml}
        _path -> {:error, :enoent}
      end,
      prompt: fn prompt ->
        send(parent, {:prompt, prompt})
        "2\n"
      end,
      interactive?: fn -> true end,
      log: fn level, message -> send(parent, {:log, level, message}) end
    }

    Enum.into(overrides, defaults)
  end
end
