defmodule SymphonyElixir.ApiGovernanceTest do
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib", __DIR__)

  test "production modules do not expose test-only public APIs" do
    matches =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_no} ->
          Regex.match?(~r/^\s*def\s+\w*_for_test\b/, line) or
            Regex.match?(~r/^\s*def\s+format_\w*_for_test\b/, line)
        end)
        |> Enum.map(fn {line, line_no} ->
          "#{Path.relative_to(path, @lib_root)}:#{line_no}:#{String.trim(line)}"
        end)
      end)

    assert matches == []
  end
end
