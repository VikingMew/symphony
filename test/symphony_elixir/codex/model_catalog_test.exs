defmodule SymphonyElixir.Codex.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.ModelCatalog

  test "catalog records the Codex implementation evidence and visible model rows" do
    assert ModelCatalog.source_evidence().codex_version == "codex-cli 0.150.1"
    assert ModelCatalog.source_evidence().model_list_request == %{"includeHidden" => false, "limit" => 100}

    assert ModelCatalog.model_ids() == [
             "gpt-5.6-sol",
             "gpt-5.6-terra",
             "gpt-5.6-luna",
             "gpt-5.5",
             "gpt-5.3-codex-spark"
           ]

    gpt_55 = Enum.find(ModelCatalog.models(), &(&1.model == "gpt-5.5"))
    assert gpt_55.id == "gpt-5.5"
    assert gpt_55.display_name == "GPT-5.5"
    assert gpt_55.default_reasoning_effort == "medium"
    assert Enum.map(gpt_55.supported_reasoning_efforts, & &1.reasoning_effort) == ~w(low medium high xhigh)
  end

  test "settings selector options and validators read the same catalog snapshot" do
    option_values = Enum.map(ModelCatalog.model_options(), fn {_label, value} -> value end)

    assert option_values == ModelCatalog.model_ids()
    assert ModelCatalog.reasoning_efforts() == ~w(low medium high xhigh max ultra)
    assert ModelCatalog.reasoning_effort_options("gpt-5.5") |> Enum.map(fn {_label, value} -> value end) == ~w(low medium high xhigh)
    assert ModelCatalog.reasoning_effort_options(nil) |> Enum.map(fn {_label, value} -> value end) == ModelCatalog.reasoning_efforts()
    assert ModelCatalog.model?("gpt-5.5")
    assert ModelCatalog.reasoning_effort?("ultra")
    assert ModelCatalog.supports_reasoning_effort?("gpt-5.6-sol", "ultra")
    assert ModelCatalog.supports_reasoning_effort?("gpt-5.5", "ultra") == false
  end
end
