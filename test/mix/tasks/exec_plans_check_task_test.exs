defmodule Mix.Tasks.ExecPlans.CheckTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ExecPlans.Check

  setup do
    Mix.Task.reenable("exec_plans.check")
    :ok
  end

  test "passes when all plans are indexed" do
    in_temp_plans_dir(fn plans_dir ->
      write_plan!(plans_dir, "completed", "001-done.md")
      write_readme!(plans_dir, completed: ["001-done.md"])

      output =
        capture_io(fn ->
          assert :ok = Check.run(["--plans-dir", plans_dir])
        end)

      assert output =~ "exec_plans.check: all exec plans are indexed"
    end)
  end

  test "raises when a plan is unlisted" do
    in_temp_plans_dir(fn plans_dir ->
      write_plan!(plans_dir, "active", "001-active.md")
      write_readme!(plans_dir)

      error_output =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/exec_plans.check failed with 1 finding/, fn ->
            Check.run(["--plans-dir", plans_dir])
          end
        end)

      assert error_output =~ "active plan files missing from README: 001-active.md"
    end)
  end

  defp in_temp_plans_dir(fun) do
    root = Path.join(System.tmp_dir!(), "exec-plans-check-task-test-#{System.unique_integer([:positive, :monotonic])}")
    plans_dir = Path.join(root, "docs/exec-plans")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(plans_dir, "active"))
    File.mkdir_p!(Path.join(plans_dir, "completed"))

    try do
      fun.(plans_dir)
    after
      File.rm_rf!(root)
    end
  end

  defp write_plan!(plans_dir, lifecycle, file) do
    File.write!(Path.join([plans_dir, lifecycle, file]), "# #{file}\n")
  end

  defp write_readme!(plans_dir, opts \\ []) do
    active = Keyword.get(opts, :active, [])
    completed = Keyword.get(opts, :completed, [])

    File.write!(Path.join(plans_dir, "README.md"), """
    # Exec Plans

    ## Completed Plans

    #{links(completed, "completed")}

    ## Intentional numbering gaps

    None.

    ## Active Plans

    #{links(active, "active")}
    """)
  end

  defp links([], _lifecycle), do: "None."

  defp links(files, lifecycle) do
    files
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {file, index} -> "#{index}. [#{file}](#{lifecycle}/#{file})" end)
  end
end
