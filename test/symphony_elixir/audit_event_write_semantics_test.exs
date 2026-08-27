defmodule SymphonyElixir.AuditEventWriteSemanticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.LinearToolAudit
  alias SymphonyElixir.PersistenceEventWriter

  defmodule RepoUnavailablePersistence do
    def record_event(_attrs), do: {:error, :repo_unavailable}
  end

  defmodule ErrorPersistence do
    def record_event(_attrs), do: {:error, :disk_full}
  end

  defmodule RaisingPersistence do
    def record_event(_attrs), do: raise("record_event exploded")
  end

  defmodule UnexpectedPersistence do
    def record_event(_attrs), do: :ok
  end

  test "event writer distinguishes repository degradation from unexpected failures" do
    attrs = %{issue_identifier: "MT-240", event_type: "run.phase", payload: %{issue_id: "issue-240"}}

    put_persistence(RepoUnavailablePersistence)

    degraded_log =
      capture_log(fn ->
        assert {:degraded, :repo_unavailable} = PersistenceEventWriter.record(attrs)
      end)

    assert degraded_log =~ "Persistence event write degraded"
    assert degraded_log =~ "issue_id=\"issue-240\""
    assert degraded_log =~ "issue_identifier=\"MT-240\""
    assert degraded_log =~ "outcome={:degraded, :repo_unavailable}"

    put_persistence(ErrorPersistence)

    error_log =
      capture_log(fn ->
        assert {:error, :disk_full} = PersistenceEventWriter.record(attrs)
      end)

    assert error_log =~ "Persistence event write failed"
    assert error_log =~ "outcome={:error, :disk_full}"

    put_persistence(UnexpectedPersistence)

    unexpected_log =
      capture_log(fn ->
        assert {:error, {:unexpected_result, :ok}} = PersistenceEventWriter.record(attrs)
      end)

    assert unexpected_log =~ "outcome={:error, {:unexpected_result, :ok}}"
  end

  test "event writer turns a raised persistence exception into a visible error" do
    put_persistence(RaisingPersistence)

    log =
      capture_log(fn ->
        assert {:error, {:exception, %RuntimeError{message: "record_event exploded"}, stacktrace}} =
                 PersistenceEventWriter.record(
                   %{issue_identifier: "MT-240", event_type: "linear.tool_call", payload: %{}},
                   %{issue_id: "issue-240", session_id: "thread-turn", run_id: "run-240"}
                 )

        assert is_list(stacktrace)
      end)

    assert log =~ "Persistence event write failed"
    assert log =~ "issue_id=\"issue-240\""
    assert log =~ "session_id=\"thread-turn\""
    assert log =~ "run_id=\"run-240\""
    refute log =~ "outcome=:ok"
  end

  test "workspace hook telemetry continues with a visible degraded outcome when persistence raises" do
    workspace_root = temporary_path("workspace")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "true"
    )

    put_persistence(RaisingPersistence)

    log =
      capture_log(fn ->
        assert {:ok, workspace} = Workspace.create_for_issue(%{id: "issue-workspace-audit", identifier: "MT-WORKSPACE-AUDIT"})
        assert File.dir?(workspace)
      end)

    assert log =~ "Workspace event persistence degraded action=continue_degraded"
    assert log =~ "issue_id=issue-workspace-audit issue_identifier=MT-WORKSPACE-AUDIT"
    assert log =~ "outcome={:degraded, {:exception, %RuntimeError{message: \"record_event exploded\"}"
  end

  test "restricted Linear tool audit returns and error-logs persistence exceptions" do
    put_persistence(RaisingPersistence)

    log =
      capture_log(fn ->
        assert {:error, {:linear_tool_audit_write_failed, {:exception, %RuntimeError{message: "record_event exploded"}, stacktrace}}} =
                 LinearToolAudit.record(
                   "linear_task_update",
                   %{"comment" => "done"},
                   %{"success" => true, "output" => "{}"},
                   issue_id: "issue-linear-audit",
                   issue_identifier: "MT-LINEAR-AUDIT",
                   session_id: "thread-240-turn-1",
                   run_id: "run-240"
                 )

        assert is_list(stacktrace)
      end)

    assert log =~ "Linear tool audit persistence failed action=surface_error"
    assert log =~ "issue_id=\"issue-linear-audit\""
    assert log =~ "issue_identifier=\"MT-LINEAR-AUDIT\""
    assert log =~ "session_id=\"thread-240-turn-1\""
    assert log =~ "run_id=\"run-240\""
    refute log =~ "outcome=:ok"
  end

  defp put_persistence(module) do
    previous = Application.get_env(:symphony_elixir, :persistence_module)
    Application.put_env(:symphony_elixir, :persistence_module, module)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :persistence_module)
      else
        Application.put_env(:symphony_elixir, :persistence_module, previous)
      end
    end)
  end

  defp temporary_path(label) do
    path = Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-audit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
