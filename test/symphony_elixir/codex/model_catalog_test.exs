defmodule SymphonyElixir.Codex.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.ModelCatalog

  test "catalog records the Codex implementation evidence and visible model rows" do
    assert ModelCatalog.source_evidence() == %{
             codex_version: "codex-cli 0.156.0",
             generated_schema_command: "codex app-server generate-json-schema --out tmp/codex-schema-sym-151-20260923",
             model_list_request: %{"includeHidden" => false, "limit" => 100},
             captured_at: "2026-09-23"
           }

    rows =
      Enum.map(ModelCatalog.models(), fn row ->
        %{
          id: row.id,
          model: row.model,
          display_name: row.display_name,
          default_reasoning_effort: row.default_reasoning_effort,
          supported_reasoning_efforts: Enum.map(row.supported_reasoning_efforts, & &1.reasoning_effort)
        }
      end)

    assert rows == [
             %{
               id: "gpt-6-astra",
               model: "gpt-6-astra",
               display_name: "GPT-6-Astra",
               default_reasoning_effort: "medium",
               supported_reasoning_efforts: ~w(low medium high xhigh max ultra)
             },
             %{
               id: "gpt-6-sol",
               model: "gpt-6-sol",
               display_name: "GPT-6-Sol",
               default_reasoning_effort: "medium",
               supported_reasoning_efforts: ~w(low medium high xhigh max ultra)
             },
             %{
               id: "gpt-6-luna",
               model: "gpt-6-luna",
               display_name: "GPT-6-Luna",
               default_reasoning_effort: "medium",
               supported_reasoning_efforts: ~w(low medium high xhigh max)
             },
             %{
               id: "gpt-5.6-sol",
               model: "gpt-5.6-sol",
               display_name: "GPT-5.6-Sol",
               default_reasoning_effort: "low",
               supported_reasoning_efforts: ~w(low medium high xhigh max ultra)
             },
             %{
               id: "gpt-5.6-terra",
               model: "gpt-5.6-terra",
               display_name: "GPT-5.6-Terra",
               default_reasoning_effort: "medium",
               supported_reasoning_efforts: ~w(low medium high xhigh max ultra)
             },
             %{
               id: "gpt-5.6-luna",
               model: "gpt-5.6-luna",
               display_name: "GPT-5.6-Luna",
               default_reasoning_effort: "medium",
               supported_reasoning_efforts: ~w(low medium high xhigh max)
             },
             %{
               id: "gpt-5.5",
               model: "gpt-5.5",
               display_name: "GPT-5.5",
               default_reasoning_effort: "medium",
               supported_reasoning_efforts: ~w(low medium high xhigh)
             }
           ]
  end

  test "settings selector options and validators read the same catalog snapshot" do
    option_values = Enum.map(ModelCatalog.model_options(), fn {_label, value} -> value end)

    assert option_values == ModelCatalog.model_ids()
    assert ModelCatalog.reasoning_efforts() == ~w(low medium high xhigh max ultra)
    assert ModelCatalog.reasoning_effort_options("gpt-5.5") |> Enum.map(fn {_label, value} -> value end) == ~w(low medium high xhigh)
    assert ModelCatalog.reasoning_effort_options(nil) |> Enum.map(fn {_label, value} -> value end) == ModelCatalog.reasoning_efforts()
    assert ModelCatalog.model?("gpt-5.5")
    assert ModelCatalog.model?("gpt-6-astra")
    assert ModelCatalog.model?("gpt-6-sol")
    assert ModelCatalog.model?("gpt-6-luna")
    assert ModelCatalog.model?("gpt-5.3-codex-spark") == false
    assert ModelCatalog.reasoning_effort?("ultra")

    assert ModelCatalog.reasoning_effort_options("gpt-6-astra") |> Enum.map(fn {_label, value} -> value end) ==
             ~w(low medium high xhigh max ultra)

    assert ModelCatalog.supports_reasoning_effort?("gpt-6-astra", "ultra")
    assert ModelCatalog.supports_reasoning_effort?("gpt-6-sol", "ultra")
    assert ModelCatalog.supports_reasoning_effort?("gpt-6-luna", "max")
    assert ModelCatalog.supports_reasoning_effort?("gpt-6-luna", "ultra") == false
    assert ModelCatalog.supports_reasoning_effort?("gpt-5.6-sol", "ultra")
    assert ModelCatalog.supports_reasoning_effort?("gpt-5.5", "ultra") == false
  end
end
