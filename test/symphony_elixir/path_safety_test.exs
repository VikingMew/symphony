defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PathSafety

  test "classifies strict canonical descendants and symlink escapes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-path-safety-#{System.unique_integer([:positive])}"
      )

    root = Path.join(test_root, "root")
    outside = Path.join(test_root, "outside")
    nonexistent_leaf = Path.join(root, "missing")
    relative_symlink = Path.join(root, "relative-link")
    absolute_symlink = Path.join(root, "absolute-link")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(Path.join("..", Path.basename(outside)), relative_symlink)
    File.ln_s!(outside, absolute_symlink)

    on_exit(fn -> File.rm_rf(test_root) end)

    canonical_root = canonicalize!(root)
    root_pair = {Path.expand(root), canonical_root}

    cases = [
      {"exact root", root, [root_pair], {:exact_root, canonical_root}},
      {"nonexistent leaf", nonexistent_leaf, [root_pair], {:inside, canonical_root}},
      {"relative symlink", relative_symlink, [root_pair], {:symlink_escape, canonical_root}},
      {"absolute symlink", absolute_symlink, [root_pair], {:symlink_escape, canonical_root}},
      {"outside root", outside, [root_pair], :outside},
      {"empty root list", nonexistent_leaf, [], :outside}
    ]

    for {scenario, path, roots, expected} <- cases do
      expanded_path = Path.expand(path)
      canonical_path = canonicalize!(expanded_path)

      assert PathSafety.classify_strict_descendant(canonical_path, expanded_path, roots) == expected,
             scenario
    end
  end

  defp canonicalize!(path) do
    assert {:ok, canonical_path} = PathSafety.canonicalize(path)
    canonical_path
  end
end
