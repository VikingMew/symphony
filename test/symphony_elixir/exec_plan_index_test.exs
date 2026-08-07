defmodule SymphonyElixir.ExecPlanIndexTest do
  use ExUnit.Case, async: true

  @plans_dir Path.expand("../../docs/exec-plans", __DIR__)

  test "exec plan README lists active and completed plan files" do
    readme = File.read!(Path.join(@plans_dir, "README.md"))

    assert linked_files(readme, "active") == plan_files("active")
    assert linked_files(readme, "completed") == plan_files("completed")
    assert root_plan_files() == []
    assert referenced_plan_numbers(readme) == disk_plan_numbers()
  end

  test "known numbering gaps are explicitly documented" do
    readme = File.read!(Path.join(@plans_dir, "README.md"))

    assert readme =~ "Intentional Numbering Gaps"
    assert readme =~ "043"
  end

  defp plan_files(section) do
    @plans_dir
    |> Path.join(section)
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.sort()
  end

  defp root_plan_files do
    @plans_dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/^\d{3}-.*\.md$/, &1))
    |> Enum.sort()
  end

  defp disk_plan_numbers do
    ["active", "completed"]
    |> Enum.flat_map(&plan_files/1)
    |> Enum.map(&plan_number/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp referenced_plan_numbers(readme) do
    Regex.scan(~r/\b(\d{3})-[^)]+\.md\)/, readme)
    |> Enum.map(fn [_match, number] -> String.to_integer(number) end)
    |> Enum.sort()
  end

  defp plan_number(file) do
    case Regex.run(~r/^(\d{3})-/, file) do
      [_match, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp linked_files(readme, section) do
    Regex.scan(~r/#{section}\/([^)\s]+\.md)/, readme)
    |> Enum.map(fn [_match, file] -> file end)
    |> Enum.sort()
  end
end
