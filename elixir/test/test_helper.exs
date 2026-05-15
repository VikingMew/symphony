ExUnit.start()

Code.require_file("support/database_isolation.exs", __DIR__)
Code.require_file("support/fake_persistence.exs", __DIR__)

dev_db = Path.expand("../symphony.db", __DIR__)
temp_root = System.tmp_dir!()

initial_repo_db =
  :symphony_elixir
  |> Application.fetch_env!(SymphonyElixir.Repo)
  |> Keyword.fetch!(:database)

SymphonyElixir.TestSupport.DatabaseIsolation.assert_safe_test_database!(initial_repo_db, dev_db, temp_root)

Application.put_env(:symphony_elixir, :start_repo, false)
Application.put_env(:symphony_elixir, :allow_test_workflow_source, true)
Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.TestSupport.FakePersistence)

on_exit = fn ->
  :ok
end

ExUnit.after_suite(fn _result -> on_exit.() end)

{:ok, _} = Application.ensure_all_started(:symphony_elixir)

Code.require_file("support/test_support.exs", __DIR__)
