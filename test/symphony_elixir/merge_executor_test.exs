defmodule SymphonyElixir.MergeExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.MergeExecutor

  test "missing merge policy records an unpushed merge and warns without failing" do
    merge_profile = Schema.default_profiles() |> Map.fetch!("merge") |> Map.delete("merge")
    refute Map.has_key?(merge_profile, "merge")

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      profiles_policy: %{"merge" => merge_profile}
    )

    issue = issue("issue-merge-no-push", "MT-MERGE-NO-PUSH")
    runner = git_runner(self(), issue.branch_name)

    log =
      capture_log(fn ->
        assert :ok =
                 MergeExecutor.run("/tmp/workspace", issue,
                   git_opts: [runner: runner],
                   merge_state_transitioner: fn _issue, _target_state -> :ok end
                 )
      end)

    assert %{push: false, pushed: false} = merge_backend_payload(issue)
    assert log =~ "Merge completed without push"
    assert log =~ "issue_id=issue-merge-no-push"
    assert log =~ "issue_identifier=MT-MERGE-NO-PUSH"
    assert log =~ "branch=feature/mt-merge"
    assert log =~ "base_branch=main"
    refute_received {:git, "/tmp/workspace", ["push", "origin", "HEAD:refs/heads/main"]}
  end

  test "enabled merge push records a pushed merge and invokes git push" do
    merge_profile =
      Schema.default_profiles()
      |> Map.fetch!("merge")
      |> put_in(["merge"], %{"push" => true, "remote" => "origin", "success_state" => "Done"})

    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "git@example.com:org/repo.git",
      profiles_policy: %{"merge" => merge_profile}
    )

    issue = issue("issue-merge-push", "MT-MERGE-PUSH")

    assert :ok =
             MergeExecutor.run("/tmp/workspace", issue,
               git_opts: [runner: git_runner(self(), issue.branch_name)],
               merge_state_transitioner: fn _issue, _target_state -> :ok end
             )

    assert %{push: true, pushed: true} = merge_backend_payload(issue)
    assert_received {:git, "/tmp/workspace", ["push", "origin", "HEAD:refs/heads/main"]}
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      state: "Ready to Merge",
      branch_name: "feature/mt-merge"
    }
  end

  defp git_runner(test_pid, branch) do
    remote_branch = "origin/#{branch}"

    fn workspace, args, _timeout_ms ->
      send(test_pid, {:git, workspace, args})

      case args do
        ["ls-remote", "--heads", "origin", ^branch] -> {"abc refs/heads/#{branch}\n", 0}
        ["ls-remote", "--heads", "origin", "main"] -> {"abc refs/heads/main\n", 0}
        ["fetch", "origin", ^branch] -> {"", 0}
        ["fetch", "origin", "main"] -> {"", 0}
        ["checkout", "--detach", "origin/main"] -> {"", 0}
        ["merge", "--no-edit", ^remote_branch] -> {"merged", 0}
        ["push", "origin", "HEAD:refs/heads/main"] -> {"pushed", 0}
      end
    end
  end

  defp merge_backend_payload(issue) do
    event =
      FakePersistence.list_events(issue_identifier: issue.identifier, event_type: "run.phase")
      |> Enum.find(fn event -> event.payload.phase == "merge_backend" end)

    assert %{payload: payload} = event
    payload
  end
end
