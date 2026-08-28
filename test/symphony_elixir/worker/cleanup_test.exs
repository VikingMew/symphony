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

  test "discovers only directories at the requested lease depth" do
    root = Path.join(System.tmp_dir!(), "worker-depth-#{System.unique_integer([:positive])}")
    lease = Path.join([root, "project", "task", "lease"])
    File.mkdir_p!(lease)

    try do
      assert Cleanup.descendants_at_depth(root, 3) == [lease]
    after
      File.rm_rf(root)
    end
  end

  test "evicts least-recent cache entries until the byte limit is bounded" do
    root = Path.join(System.tmp_dir!(), "worker-cache-#{System.unique_integer([:positive])}")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    File.mkdir_p!(root)
    File.write!(first, "12345")
    File.write!(second, "67890")
    File.touch!(first, 1)
    File.touch!(second, 2)

    try do
      assert {:ok, [^first]} = Cleanup.evict_cache(root, 5, 1_000_000_000, DateTime.from_unix!(2))
      refute File.exists?(first)
      assert File.exists?(second)
    after
      File.rm_rf(root)
    end
  end
end
