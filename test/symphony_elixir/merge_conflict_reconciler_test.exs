defmodule SymphonyElixir.MergeConflictReconcilerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MergeConflictReconciler
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous_persistence = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)
    FakePersistence.reset!()

    FakePersistence.put_issues([
      %{
        identifier: "SYM-17",
        tracker_issue_id: "issue-17",
        state: "Ready to Merge",
        blocking_decision: nil,
        no_progress_streak: 0
      }
    ])

    FakePersistence.put_events([
      %{
        event_type: "run.phase",
        issue_identifier: "SYM-17",
        run_id: "run-handoff",
        occurred_at: DateTime.utc_now(),
        payload: %{
          phase: "implementation_handoff",
          status: "completed",
          url: "https://github.com/acme/app/pull/17"
        }
      }
    ])

    on_exit(fn ->
      restore_app_env(:persistence_module, previous_persistence)
    end)

    :ok
  end

  test "persists and delivers an exact deterministic conflict with handoff provenance" do
    lookup = fn _issue, _project, _opts ->
      {:ok,
       %{
         url: "https://github.com/acme/app/pull/17",
         repository: "acme/app",
         base: "main",
         head: "vikingmew-sym-17",
         raw_status: "CONFLICTING",
         conflicting: true
       }}
    end

    assert {:blocked, decision, {:ok, %{comment: :ok, transition: :ok}}} =
             MergeConflictReconciler.reconcile(issue(), project(), reconcile_opts(lookup))

    assert decision["reason"] == "merge_conflict"
    assert decision["run_id"] == "run-handoff"
    assert decision["references"]["pr_url"] == "https://github.com/acme/app/pull/17"
    assert_receive {:delivery, "issue-17", "SYM-17"}

    assert [event] =
             FakePersistence.list_events(event_type: "issue.merge_conflict_detected")

    assert event.run_id == "run-handoff"
    assert event.payload.pr_url == "https://github.com/acme/app/pull/17"
  end

  test "does not persist unknown mergeability" do
    lookup = fn _issue, _project, _opts ->
      {:ok,
       %{
         url: "https://github.com/acme/app/pull/17",
         repository: "acme/app",
         base: "main",
         head: "vikingmew-sym-17",
         raw_status: "UNKNOWN",
         conflicting: false
       }}
    end

    assert :unchanged =
             MergeConflictReconciler.reconcile(issue(), project(), reconcile_opts(lookup))

    assert FakePersistence.get_issue_by_identifier("SYM-17").blocking_decision == nil
    refute_receive {:delivery, _, _}
  end

  test "keeps typed GitHub lookup failures retryable without persisting a decision" do
    lookup = fn _issue, _project, _opts ->
      {:error, {:github_http_request_failed, "timeout"}}
    end

    assert {:error, {:github_http_request_failed, "timeout"}} =
             MergeConflictReconciler.reconcile(issue(), project(), reconcile_opts(lookup))

    assert FakePersistence.get_issue_by_identifier("SYM-17").blocking_decision == nil
    refute_receive {:delivery, _, _}
  end

  test "drops the decision when the issue leaves Ready to Merge during revalidation" do
    lookup = fn _issue, _project, _opts ->
      {:ok,
       %{
         url: "https://github.com/acme/app/pull/17",
         repository: "acme/app",
         base: "main",
         head: "vikingmew-sym-17",
         raw_status: "dirty",
         conflicting: true
       }}
    end

    opts =
      reconcile_opts(lookup,
        issue_state_fetcher: fn ["issue-17"] ->
          {:ok, [%{issue() | state: "In Progress"}]}
        end
      )

    assert :stale = MergeConflictReconciler.reconcile(issue(), project(), opts)
    assert FakePersistence.get_issue_by_identifier("SYM-17").blocking_decision == nil
  end

  defp issue do
    %Issue{
      id: "issue-17",
      identifier: "SYM-17",
      state: "Ready to Merge",
      branch_name: "vikingmew-sym-17"
    }
  end

  defp project do
    %Schema.Project{
      repository_url: "git@github.com:acme/app.git",
      default_branch: "main"
    }
  end

  defp reconcile_opts(lookup, overrides \\ []) do
    test_pid = self()

    defaults = [
      mergeability: lookup,
      issue_state_fetcher: fn ["issue-17"] -> {:ok, [issue()]} end,
      delivery: fn issue_id, identifier ->
        send(test_pid, {:delivery, issue_id, identifier})
        {:ok, %{comment: :ok, transition: :ok}}
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
