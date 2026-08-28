defmodule SymphonyElixir.Worker.CleanupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Cleanup

  test "preserves active directories and removes only expired contained entries" do
    root = Path.join(System.tmp_dir!(), "worker-cleanup-#{System.unique_integer([:positive])}")
    active = Path.join(root, "active")
    expired = Path.join(root, "expired")
    File.mkdir_p!(active)
    File.mkdir_p!(expired)

    try do
      future = DateTime.add(DateTime.utc_now(), 120, :second)
      assert {:ok, [^expired]} = Cleanup.remove_expired(root, MapSet.new([active]), 60, future)
      assert File.dir?(active)
      refute File.exists?(expired)
    after
      File.rm_rf(root)
    end
  end
end
