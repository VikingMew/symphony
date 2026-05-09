defmodule SymphonyElixir.MergeFlowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{BranchName, MergeExecutor}
  alias SymphonyElixir.Codex.DynamicTool

  test "branch name validator accepts linear branch names and rejects unsafe refs" do
    assert {:ok, "feature/ccr-3"} = BranchName.validate("feature/ccr-3")
    assert {:ok, "fix_123.audit"} = BranchName.validate("fix_123.audit")

    assert {:error, {:invalid_linear_branch_name, :non_ascii}} = BranchName.validate("功能/修复")
    assert {:error, {:invalid_linear_branch_name, :whitespace}} = BranchName.validate("feature/ccr 3")
    assert {:error, {:invalid_linear_branch_name, {:unsafe_fragment, ".."}}} = BranchName.validate("feature/../../bad")
    assert {:error, {:invalid_linear_branch_name, :leading_dash}} = BranchName.validate("-bad")
    assert {:error, :missing_linear_branch_name} = BranchName.validate(nil)
  end

  test "implementation update refuses review transition when linear branch is not pushed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git"
    )

    issue = %Issue{
      id: "issue-branch-missing",
      identifier: "MT-BRANCH-MISSING",
      state: "In Progress",
      branch_name: "feature/ccr-3"
    }

    result =
      DynamicTool.execute(
        "linear_task_update",
        %{"target_state" => "Needs Implementation Review", "comment" => "ready"},
        issue: issue,
        profile: "implementation",
        workspace: "/tmp/workspace",
        branch_remote_checker: fn "/tmp/workspace", "feature/ccr-3" -> {:ok, false} end
      )

    refute result["success"]
    assert result["output"] =~ "linear_branch_not_pushed"
  end

  test "implementation update allows review transition after linear branch is pushed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git"
    )

    issue = %Issue{
      id: "issue-branch-pushed",
      identifier: "MT-BRANCH-PUSHED",
      state: "In Progress",
      branch_name: "feature/ccr-3"
    }

    graphql = fn
      _query, %{"id" => "issue-branch-pushed", "input" => %{"stateId" => "state-review"}} ->
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

      _query, %{"id" => "issue-branch-pushed"} ->
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{"states" => %{"nodes" => [%{"id" => "state-review", "name" => "Needs Implementation Review"}]}}
             }
           }
         }}
    end

    result =
      DynamicTool.execute(
        "linear_task_update",
        %{"target_state" => "Needs Implementation Review"},
        issue: issue,
        profile: "implementation",
        workspace: "/tmp/workspace",
        branch_remote_checker: fn "/tmp/workspace", "feature/ccr-3" -> {:ok, true} end,
        graphql: graphql
      )

    assert result["success"]
  end

  test "merge executor reads Linear branchName and runs backend git merge without push by default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git"
    )

    issue = %Issue{
      id: "issue-merge",
      identifier: "MT-MERGE",
      state: "Ready to Merge",
      branch_name: "feature/ccr-3"
    }

    test_pid = self()

    runner = fn workspace, args, _timeout_ms ->
      send(test_pid, {:git, workspace, args})

      case args do
        ["ls-remote", "--heads", "origin", "feature/ccr-3"] -> {"abc refs/heads/feature/ccr-3\n", 0}
        ["fetch", "origin", "feature/ccr-3"] -> {"", 0}
        ["checkout", "main"] -> {"", 0}
        ["merge", "--no-edit", "origin/feature/ccr-3"] -> {"merged", 0}
      end
    end

    transitioner = fn transition_issue, target_state ->
      send(test_pid, {:transition, transition_issue.state, target_state})
      :ok
    end

    assert :ok =
             MergeExecutor.run("/tmp/workspace", issue,
               git_opts: [runner: runner],
               merge_state_transitioner: transitioner
             )

    assert_receive {:transition, "Ready to Merge", "Merging"}
    assert_receive {:transition, "Merging", "Done"}
    assert_receive {:git, "/tmp/workspace", ["ls-remote", "--heads", "origin", "feature/ccr-3"]}
    assert_receive {:git, "/tmp/workspace", ["fetch", "origin", "feature/ccr-3"]}
    assert_receive {:git, "/tmp/workspace", ["checkout", "main"]}
    assert_receive {:git, "/tmp/workspace", ["merge", "--no-edit", "origin/feature/ccr-3"]}
    refute_receive {:git, "/tmp/workspace", ["push", "origin", "main"]}
  end

  test "agent runner dispatches merge profile to backend executor without starting Codex" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-merge-agent-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf ready > README.md",
        codex_command: "/bin/false app-server"
      )

      issue = %Issue{
        id: "issue-agent-merge",
        identifier: "MT-AGENT-MERGE",
        state: "Ready to Merge",
        branch_name: "feature/ccr-3"
      }

      test_pid = self()

      merge_executor = fn workspace, merge_issue, _opts ->
        send(test_pid, {:merge_executor_called, workspace, merge_issue.branch_name})
        :ok
      end

      assert :ok = AgentRunner.run(issue, nil, merge_executor: merge_executor)
      assert_receive {:merge_executor_called, workspace, "feature/ccr-3"}
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "merge executor fails before git when Linear branchName is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git"
    )

    issue = %Issue{id: "issue-merge-missing", identifier: "MT-MERGE-MISSING", state: "Ready to Merge"}

    assert {:error, :missing_linear_branch_name} = MergeExecutor.run("/tmp/workspace", issue)
  end
end
