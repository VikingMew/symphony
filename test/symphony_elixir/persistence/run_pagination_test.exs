defmodule SymphonyElixir.Persistence.RunPaginationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Persistence.RunRecord
  alias SymphonyElixir.TestSupport.FakePersistence

  setup do
    FakePersistence.reset!()
    :ok
  end

  test "list_runs_page paginates by inserted_at and id without duplicates" do
    now = DateTime.utc_now()

    runs =
      for index <- 1..30 do
        %{
          id: "run-#{index}",
          kind: "issue",
          issue_identifier: "CCR-#{index}",
          status: "running",
          started_at: DateTime.add(now, -index, :second),
          inserted_at: DateTime.add(now, -index, :second)
        }
      end

    FakePersistence.put_runs(runs)

    first = FakePersistence.list_runs_page(page_size: 25)
    second = FakePersistence.list_runs_page(page_size: 25, cursor: first.next_cursor)

    assert length(first.entries) == 25
    assert first.has_more?
    assert length(second.entries) == 5
    refute second.has_more?

    ids = Enum.map(first.entries ++ second.entries, & &1.id)
    assert Enum.sort(ids) == runs |> Enum.map(& &1.id) |> Enum.sort()
    assert Enum.uniq(ids) == ids
  end

  test "operator runs do not require issue identifiers" do
    changeset =
      RunRecord.changeset(%RunRecord{}, %{
        kind: "nap",
        label: "Nap",
        profile: "nap",
        status: "running"
      })

    assert changeset.valid?
  end
end
