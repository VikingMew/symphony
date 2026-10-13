defmodule Mix.Tasks.ObservabilityBaselineTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Observability.Check

  setup do
    Mix.Task.reenable("observability.check")
    :ok
  end

  test "checked-in baseline passes and write-baseline is byte-idempotent" do
    path = "config/observability_baseline.yml"
    before = File.read!(path)
    on_exit(fn -> File.write!(path, before) end)

    assert capture_io(fn -> assert nil == Check.run([]) end) ==
             "observability baseline remaining: 168\n"

    Mix.Task.reenable("observability.check")
    output = capture_io(fn -> assert nil == Check.run(["--write-baseline"]) end)

    assert output == "observability baseline remaining: 168\n"
    assert File.read!(path) == before
  end

  test "arguments fail with the stable usage" do
    assert_raise Mix.Error, ~r/usage: mix observability.check/, fn -> Check.run(["--warn"]) end
  end
end
