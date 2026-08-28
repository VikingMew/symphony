defmodule SymphonyElixir.Worker.PathsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Paths

  test "rejects traversal and symlink escape" do
    root = Path.join(System.tmp_dir!(), "worker-paths-#{System.unique_integer([:positive])}")
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    try do
      File.ln_s!(outside, Path.join(root, "escape"))
      assert {:error, :path_escape} = Paths.contained_join(root, ["..", "bad"])
      assert {:error, :path_escape} = Paths.contained_join(root, ["escape", "lease"])
      assert {:error, :path_escape} = Paths.remove_contained(root, outside)
    after
      File.rm_rf(root)
      File.rm_rf(outside)
    end
  end
end
