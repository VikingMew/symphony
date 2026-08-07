defmodule SymphonyElixir.DynamicAtomUsageTest do
  use ExUnit.Case, async: true

  @moduledoc false

  test "runtime lib code does not convert external strings into atoms dynamically" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        for forbidden <- ["String.to_atom(", "String.to_existing_atom("],
            String.contains?(source, forbidden) do
          "#{path}: #{forbidden}"
        end
      end)

    assert offenders == []
  end
end
