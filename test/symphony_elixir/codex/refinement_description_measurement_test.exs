defmodule SymphonyElixir.Codex.RefinementDescriptionMeasurementTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RefinementDescriptionMeasurement, as: Measurement

  test "counts Unicode characters and normalized logical lines at strict boundaries" do
    limits = %{"characters" => 5, "lines" => 3, "label_overrides" => %{}}

    assert %{characters: 5, lines: 3, over_limit: false} = Measurement.measure("猫\r\na\rb", [], limits)
    assert %{characters: 6, lines: 3, over_limit: true} = Measurement.measure("猫猫\r\na\rb", [], limits)
  end

  test "normalizes labels and chooses the most permissive dimensions deterministically" do
    limits = %{
      "characters" => 10,
      "lines" => 10,
      "label_overrides" => %{
        " Backend " => %{"characters" => 20, "lines" => 12},
        "COMPLEX" => %{"characters" => 15, "lines" => 30}
      }
    }

    assert %{
             character_limit: 20,
             line_limit: 30,
             label_overrides: [%{label: "backend"}, %{label: "complex"}]
           } = Measurement.measure("short", ["backend", "Complex"], limits)
  end
end
