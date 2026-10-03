defmodule Scripts.NegativeAssertionInventoryTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "negative-inventory-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(Path.join(root, "test"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "emits a stable row for each negative assertion and escapes tabs", %{root: root} do
    File.write!(Path.join(root, "test/sample_test.exs"), "refute value == false\nflunk(\"bad\\tvalue\")\n")

    {output, 0} = System.cmd("elixir", [script_path()], cd: root)

    assert output ==
             "file\tline\tmacro\tcategory\tdecision\tcontract\tsource\n" <>
               "test/sample_test.exs\t1\trefute\tstructure-data\trewrite-exact\ttested data/state contract\trefute value == false\n" <>
               "test/sample_test.exs\t2\tflunk\tcontrol-flow\trewrite-match\texplicit success shape\tflunk(\"bad\\tvalue\")\n"
  end

  test "emits only the header when no negative assertion exists", %{root: root} do
    File.write!(Path.join(root, "test/sample_test.exs"), "assert value == true\n")

    assert {"file\tline\tmacro\tcategory\tdecision\tcontract\tsource\n", 0} =
             System.cmd("elixir", [script_path()], cd: root)
  end

  defp script_path do
    Path.expand("scripts/negative_assertion_inventory.exs", File.cwd!())
  end
end
