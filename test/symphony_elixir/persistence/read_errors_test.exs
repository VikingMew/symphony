defmodule SymphonyElixir.Persistence.ReadErrorsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Persistence

  setup do
    on_exit(&stop_repo_stub/0)
    :ok
  end

  test "read APIs return repo_unavailable instead of empty values when the Repo is down" do
    refute Process.whereis(SymphonyElixir.Repo)

    assert {:error, :repo_unavailable} = Persistence.list_projects()
    assert {:error, :repo_unavailable} = Persistence.list_runs_for_issue("SYM-239")
    assert {:error, :repo_unavailable} = Persistence.list_runs()
    assert {:error, :repo_unavailable} = Persistence.list_runs_page()
    assert {:error, :repo_unavailable} = Persistence.list_events()
  end

  test "read APIs return typed query failures when Repo queries raise" do
    _pid = start_repo_stub!()

    assert_query_failed(Persistence.list_projects())
    assert_query_failed(Persistence.list_runs_for_issue("SYM-239"))
    assert_query_failed(Persistence.list_runs())
    assert_query_failed(Persistence.list_runs_page())
    assert_query_failed(Persistence.list_events())
  end

  defp assert_query_failed({:error, {:query_failed, %ArgumentError{}}}), do: :ok

  defp start_repo_stub! do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    true = Process.register(pid, SymphonyElixir.Repo)
    pid
  end

  defp stop_repo_stub do
    case Process.whereis(SymphonyElixir.Repo) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end
  end
end
