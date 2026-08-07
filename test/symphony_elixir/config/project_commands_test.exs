defmodule SymphonyElixir.Config.ProjectCommandsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.ProjectCommands
  alias SymphonyElixir.Config.Schema

  test "generates clone bootstrap commands with branch depth and setup commands" do
    project = %Schema.Project{
      repository_url: "https://github.com/example/repo.git",
      default_branch: "main",
      checkout_depth: 2,
      source_strategy: "clone",
      setup_commands: ["mix deps.get"]
    }

    commands = ProjectCommands.generated_project_bootstrap_commands(project)

    assert commands =~
             "git -c credential.helper= -c core.askPass= -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone --progress --depth 2 --branch 'main' 'https://github.com/example/repo.git' ."

    assert commands =~ "\nmix deps.get"
  end

  test "adds noninteractive ssh options for ssh repository urls" do
    project = %Schema.Project{
      repository_url: "git@github.com:example/repo.git",
      default_branch: "main",
      checkout_depth: 1,
      source_strategy: "clone"
    }

    commands = ProjectCommands.generated_project_bootstrap_commands(project)

    assert commands =~ "GIT_SSH_COMMAND="
    assert commands =~ "BatchMode=yes"
    assert commands =~ "StrictHostKeyChecking=accept-new"
  end

  test "does not generate clone command for worktree strategy" do
    project = %Schema.Project{
      repository_url: "git@github.com:example/repo.git",
      source_strategy: "worktree",
      setup_commands: ["mise install"]
    }

    assert ProjectCommands.generated_project_bootstrap_commands(project) == "mise install"
  end

  test "generates setup-only and cleanup-only command blocks" do
    project = %Schema.Project{
      setup_commands: ["  mix deps.get  ", ""],
      cleanup_commands: [" git worktree prune "]
    }

    assert ProjectCommands.project_setup_commands(project) == "mix deps.get"
    assert ProjectCommands.generated_before_remove_hook(project) == "git worktree prune"
  end
end
