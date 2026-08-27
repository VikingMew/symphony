defmodule SymphonyElixir.PersistenceProviderTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PersistenceProvider
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    previous = Application.get_env(:symphony_elixir, :persistence_module)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :persistence_module, previous)
      else
        Application.delete_env(:symphony_elixir, :persistence_module)
      end
    end)

    :ok
  end

  test "defaults to real persistence" do
    Application.delete_env(:symphony_elixir, :persistence_module)

    assert PersistenceProvider.module() == SymphonyElixir.Persistence
  end

  test "uses configured fake persistence" do
    Application.put_env(:symphony_elixir, :persistence_module, FakePersistence)

    assert PersistenceProvider.module() == FakePersistence
  end

  test "normalizes thrown reads and preserves production mutation success" do
    assert {:error, {:query_failed, {:throw, :busy}}} = PersistenceProvider.read(fn -> throw(:busy) end)

    Application.put_env(:symphony_elixir, :persistence_module, SymphonyElixir.Persistence)
    assert {:ok, :persisted} = PersistenceProvider.publish_runtime_mutation({:ok, :persisted})
  end
end
