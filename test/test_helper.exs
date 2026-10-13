ExUnit.start(seed: 0)

Code.require_file("support/outbound_http_guard.exs", __DIR__)
Code.require_file("support/retry_timer_assertions.exs", __DIR__)

if System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" do
  Req.default_options(finch_request: &SymphonyElixir.TestSupport.OutboundHttpGuard.guarded_finch_request/4)
end

Code.require_file("support/fake_persistence.exs", __DIR__)

Application.stop(:symphony_elixir)

Application.put_env(:symphony_elixir, :start_repo, false)
Application.put_env(:symphony_elixir, :start_http_server, false)
Application.put_env(:symphony_elixir, :allow_test_workflow_source, true)
Application.put_env(:symphony_elixir, :runtime_role, :panel)
Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.TestSupport.FakePersistence)
Application.put_env(:symphony_elixir, :fake_persistence, repo_available?: true)

on_exit = fn ->
  :ok
end

ExUnit.after_suite(fn _result -> on_exit.() end)

{:ok, _} = Application.ensure_all_started(:symphony_elixir)

Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/settings_fake_persistence_support.exs", __DIR__)

Path.join(__DIR__, "support/locality_sections/*.exs")
|> Path.wildcard()
|> Enum.each(&Code.require_file/1)
