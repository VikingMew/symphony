ExUnit.start()

Code.require_file("support/fake_persistence.exs", __DIR__)

Application.put_env(:symphony_elixir, :start_repo, false)
Application.put_env(:symphony_elixir, :start_http_server, false)
Application.put_env(:symphony_elixir, :allow_test_workflow_source, true)
Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.TestSupport.FakePersistence)

on_exit = fn ->
  :ok
end

ExUnit.after_suite(fn _result -> on_exit.() end)

{:ok, _} = Application.ensure_all_started(:symphony_elixir)

Code.require_file("support/test_support.exs", __DIR__)
