defmodule SymphonyElixir.FirstRunDefaultsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FirstRunDefaults

  @workflow_yaml """
  tracker:
    active_states: [Ready]
    terminal_states: [Done]
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
    refute prompt =~ "Disabled"
    assert_received {:import_workflow, %{id: "project-beta"}, raw, "first_run_default_yaml"}
    assert raw =~ "Default imported base prompt."
    assert raw =~ "implementation"
  end

  test "declining first-run prompt leaves database unchanged" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, prompt: fn _prompt -> "no\n" end))
    refute_received {:import_workflow, _, _, _}
  end

  test "opt-out flag skips prompt and import" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([no_default_yaml_prompt: true], deps(parent))
    refute_received {:prompt, _}
    refute_received {:import_workflow, _, _, _}
  end

  test "existing workflow skips default package reads" do
    parent = self()

    deps =
      deps(parent,
        current_workflow: fn -> %{id: "current"} end,
        read_file: fn path ->
          send(parent, {:unexpected_read, path})
          {:error, :enoent}
        end
      )

    assert :ok = FirstRunDefaults.maybe_import([], deps)
    refute_received {:unexpected_read, _}
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
    refute_received {:import_workflow, _, _, _}
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
    refute_received {:import_workflow, _, _, _}
  end

  test "non-interactive startup logs available defaults without prompting" do
    parent = self()

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, interactive?: fn -> false end))
    refute_received {:prompt, _}
    refute_received {:import_workflow, _, _, _}
  end

  test "zero-project interactive startup imports into the bootstrap project" do
    parent = self()

    {_agent, deps} =
      zero_project_bootstrap_deps(parent,
        prompt: fn prompt ->
          send(parent, {:prompt, prompt})
          "1\n"
        end
      )

    assert :ok = FirstRunDefaults.maybe_import([], deps)
    assert_received {:prompt, prompt}
    assert prompt =~ "1) Default (default)"

    assert_received {:import_workflow, project, raw, "first_run_default_yaml"}
    assert project.slug == "default"
    assert raw =~ "Default imported base prompt."
  end

  test "zero-project non-interactive startup logs and leaves the bootstrap project" do
    parent = self()
    {agent, deps} = zero_project_bootstrap_deps(parent, interactive?: fn -> false end)

    assert :ok = FirstRunDefaults.maybe_import([], deps)
    assert [%{slug: "default", enabled: true}] = Agent.get(agent, & &1.projects)
    refute_received {:prompt, _}
    refute_received {:import_workflow, _, _, _}
    assert_received {:log, :info, message}
    assert message =~ "non-interactive"
  end

  test "startup without enabled projects remains setup-required without prompting" do
    parent = self()

    disabled_project = %{id: "project-disabled", name: "Disabled", slug: "disabled", enabled: false}

    assert :ok = FirstRunDefaults.maybe_import([], deps(parent, list_projects: fn -> [disabled_project] end))
    refute_received {:prompt, _}
    refute_received {:import_workflow, _, _, _}
    assert_received {:log, :info, message}
    assert message =~ "No enabled projects"
  end

  defp zero_project_bootstrap_deps(parent, overrides) do
    {:ok, agent} = Agent.start_link(fn -> %{projects: []} end)
    bootstrap = %{id: "bootstrap-project", name: "Default", slug: "default", enabled: true}

    bootstrap_overrides = [
      current_workflow: fn ->
        Agent.update(agent, fn
          %{projects: []} = state -> %{state | projects: [bootstrap]}
          state -> state
        end)

        nil
      end,
      list_projects: fn -> Agent.get(agent, & &1.projects) end
    ]

    {agent, deps(parent, Keyword.merge(bootstrap_overrides, overrides))}
  end

  defp deps(parent, overrides \\ []) do
    defaults = %{
      current_workflow: fn -> nil end,
      list_projects: fn ->
        [
          %{id: "project-alpha", name: "Alpha", slug: "alpha", enabled: true},
          %{id: "project-disabled", name: "Disabled", slug: "disabled", enabled: false},
          %{id: "project-beta", name: "Beta", slug: "beta", enabled: true}
        ]
      end,
      import_workflow: fn project, raw, source ->
        send(parent, {:import_workflow, project, raw, source})
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
