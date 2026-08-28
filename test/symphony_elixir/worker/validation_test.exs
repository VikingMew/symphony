defmodule SymphonyElixir.Worker.ValidationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Worker.Validation

  test "uses exactly the five contract outcomes" do
    assert Validation.outcomes() == [:passed, :failed, :timed_out, :cancelled, :toolchain_unavailable]
  end

  test "stops ordered gates at the first non-passing result" do
    runner = fn gate, _cwd -> %{status: gate.status, exit_code: nil, duration_ms: 1, detail: ""} end
    gates = [%{command: "one", status: :passed}, %{command: "two", status: :failed}, %{command: "three", status: :passed}]
    result = Validation.run(gates, "/tmp", runner)
    assert result.overall_status == :failed
    assert Enum.map(result.gates, & &1.command) == ["one", "two"]
  end

  test "redacts credential-shaped values in validation.json" do
    path = Path.join(System.tmp_dir!(), "validation-#{System.unique_integer([:positive])}.json")
    assert :ok = Validation.write!(path, %{token: "sensitive", nested: %{password: "bad"}})
    contents = File.read!(path)
    assert contents =~ "[REDACTED]"
    refute contents =~ "sensitive"
    refute contents =~ "bad"
    File.rm!(path)
  end
end
