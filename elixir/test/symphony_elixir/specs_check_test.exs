defmodule SymphonyElixir.SpecsCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SpecsCheck

  test "reports missing @spec for public functions" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def missing(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.missing/1"]
  end

  test "accepts adjacent @spec on public function" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec ok(term()) :: term()
      def ok(arg), do: arg
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "allows defp without @spec" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def public do
        helper(:ok)
      end

      defp helper(value), do: value
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.public/0"]
  end

  test "exempts callback implementations marked with @impl" do
    dir = create_tmp_dir()

    write_module!(dir, "worker.ex", """
    defmodule Worker do
      @behaviour GenServer

      @impl true
      def init(state), do: {:ok, state}
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "honors explicit exemptions list" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def legacy(arg), do: arg
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir], exemptions: ["Sample.legacy/1"])

    assert findings == []
  end

  test "accepts @spec before a bare function head with multi-clause defs" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      @spec normalize(term(), term()) :: term()
      def normalize(value, default \\\\ nil)

      def normalize(value, default) when is_binary(value), do: value
      def normalize(_value, default), do: default
    end
    """)

    assert SpecsCheck.missing_public_specs([dir]) == []
  end

  test "reports missing @spec before a bare function head" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def normalize(value, default \\\\ nil)

      def normalize(value, default) when is_binary(value), do: value
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.normalize/2"]
  end

  test "reports missing @spec when it appears after a bare function head" do
    dir = create_tmp_dir()

    write_module!(dir, "sample.ex", """
    defmodule Sample do
      def normalize(value, default \\\\ nil)

      @spec normalize(term(), term()) :: term()
      def normalize(value, default) when is_binary(value), do: value
    end
    """)

    findings = SpecsCheck.missing_public_specs([dir])

    assert Enum.map(findings, &SpecsCheck.finding_identifier/1) == ["Sample.normalize/2"]
  end

  defp create_tmp_dir do
    unique = :erlang.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "specs-check-test-#{unique}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp write_module!(dir, rel_path, source) do
    path = Path.join(dir, rel_path)
    File.write!(path, source)
  end
end
