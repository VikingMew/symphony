ExUnit.start()

Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:ecto_sqlite3)

test_db =
  Path.join(System.tmp_dir!(), "symphony-elixir-test-#{System.unique_integer([:positive])}.db")

Application.put_env(:symphony_elixir, SymphonyElixir.Repo,
  database: test_db,
  pool_size: 5
)

on_exit = fn ->
  File.rm_rf(test_db)
  File.rm_rf(test_db <> "-shm")
  File.rm_rf(test_db <> "-wal")
end

ExUnit.after_suite(fn _result -> on_exit.() end)

{:ok, _} = Application.ensure_all_started(:symphony_elixir)

Ecto.Migrator.run(
  SymphonyElixir.Repo,
  Path.expand("../priv/repo/migrations", __DIR__),
  :up,
  all: true
)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
