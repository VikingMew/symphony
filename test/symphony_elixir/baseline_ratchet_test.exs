defmodule SymphonyElixir.BaselineRatchetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.BaselineRatchet

  test "builds byte-stable replacement and deletion candidates" do
    encode = fn entries -> Jason.encode!(entries, pretty: true) end

    assert BaselineRatchet.baseline_candidate([], encode) == :delete

    assert BaselineRatchet.baseline_candidate([%{"key" => "value"}], encode) ==
             {:replace, "[\n  {\n    \"key\": \"value\"\n  }\n]\n"}
  end

  test "reports only multiset counts above the merge-base ceiling" do
    assert BaselineRatchet.multiset_ceiling([:kept], [:kept, :removed], & &1) == :ok

    assert BaselineRatchet.multiset_ceiling([:same, :same], [:same], & &1) ==
             {:error, [%{key: :same, base_count: 1, current_count: 2}]}
  end

  test "keeps target bytes on validation failure and makes repeat writes no-ops" do
    root = Path.join(System.tmp_dir!(), "baseline-ratchet-#{System.unique_integer([:positive])}")
    path = Path.join(root, "baseline.yml")
    File.mkdir_p!(root)
    File.write!(path, "before\n")
    on_exit(fn -> File.rm_rf!(root) end)

    candidate = {:replace, "after\n"}
    assert {:error, ["blocked"]} = BaselineRatchet.replace_baseline(path, candidate, ["blocked"])
    assert File.read!(path) == "before\n"
    assert {:ok, :written} = BaselineRatchet.replace_baseline(path, candidate, [])
    assert {:ok, :unchanged} = BaselineRatchet.replace_baseline(path, candidate, [])
    assert File.read!(path) == "after\n"
  end
end
