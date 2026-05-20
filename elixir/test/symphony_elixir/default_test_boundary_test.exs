defmodule SymphonyElixir.DefaultTestBoundaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PersistenceProvider
  alias SymphonyElixir.TestSupport.FakePersistence

  test "default suite uses fake persistence and does not start Repo" do
    refute Process.whereis(SymphonyElixir.Repo)
    assert Application.fetch_env!(:symphony_elixir, :start_repo) == false
    assert PersistenceProvider.module() == FakePersistence
  end

  test "default suite does not create sqlite files under the test temp root" do
    temp_root = System.tmp_dir!()

    symphony_sqlite_files =
      temp_root
      |> Path.join("**/*.{sqlite,sqlite-wal,sqlite-shm,db,db-wal,db-shm}")
      |> Path.wildcard()
      |> Enum.filter(&symphony_temp_file?/1)

    assert symphony_sqlite_files == []
  end

  defp symphony_temp_file?(path) do
    path
    |> String.downcase()
    |> String.contains?("symphony")
  end
end
