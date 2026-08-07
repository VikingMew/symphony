defmodule SymphonyElixir.NapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Nap.Results

  test "deduplicates findings within one run and counts outcomes" do
    finding = %{
      "title" => "Remove compatibility shim",
      "category" => "compatibility code",
      "path" => "lib/example.ex",
      "evidence" => "The shim is no longer used."
    }

    summary =
      Results.aggregate([finding, finding, Map.put(finding, "title", "Missing product affordance")], fn payload ->
        {:ok, %{"identifier" => "CCR-#{payload["title"]}"}}
      end)

    assert summary.created == 2
    assert summary.skipped == 1
    assert summary.failed == 0
    assert Enum.map(summary.results, & &1.status) == [:created, :skipped_duplicate, :created]
  end

  test "records validation and create failures" do
    summary =
      Results.aggregate(
        [
          %{"title" => "", "category" => "bad smell", "evidence" => "missing title"},
          %{"title" => "API gap", "category" => "product gap", "evidence" => "docs mention it"}
        ],
        fn _payload -> {:error, :linear_down} end
      )

    assert summary.created == 0
    assert summary.skipped == 0
    assert summary.failed == 2
    assert Enum.map(summary.results, & &1.status) == [:validation_failed, :create_failed]
  end
end
