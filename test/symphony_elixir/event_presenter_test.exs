defmodule SymphonyElixir.EventPresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.EventPresenter

  test "hides repeated legacy empty codex notifications by default" do
    events = [
      %{event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}},
      %{event_type: "codex.update", payload: %{"event" => "notification", "message" => nil}},
      %{event_type: "run.started", payload: %{"message" => "started"}}
    ]

    rows = EventPresenter.rows(events)

    assert rows.hidden_low_signal_count == 2
    assert Enum.map(rows.visible, & &1.event_type) == ["run.started"]

    revealed = EventPresenter.rows(events, hide_low_signal?: false)
    assert revealed.hidden_low_signal_count == 0
    assert Enum.count(revealed.visible, & &1.low_signal?) == 2
    assert revealed.visible |> hd() |> Map.fetch!(:detail) =~ "detailed payload was not persisted"
  end

  test "classifies failed run workspace and linear events" do
    run_failed =
      EventPresenter.row(%{
        event_type: "run.failed",
        payload: %{"failure_reason" => "workspace timeout"}
      })

    assert run_failed.source == :system
    assert run_failed.severity == :error
    assert run_failed.summary =~ "workspace timeout"

    workspace =
      EventPresenter.row(%{
        event_type: "workspace.phase",
        payload: %{"status" => "failed", "phase" => "workspace_bootstrap", "recent_output" => "clone timed out"}
      })

    assert workspace.source == :workspace
    assert workspace.severity == :error
    assert workspace.category == :workspace

    linear =
      EventPresenter.row(%{
        event_type: "linear.state_transition",
        payload: %{"from_state" => "In Progress", "to_state" => "Review"}
      })

    assert linear.source == :linear
    assert linear.summary == "Linear state moved In Progress -> Review"
  end

  test "scrubs sensitive raw payload fields" do
    row =
      EventPresenter.row(%{
        event_type: "run.failed",
        payload: %{
          "message" => "failed",
          "authorization" => "Bearer secret-token",
          "nested" => %{"cookie" => "session=secret-cookie"}
        }
      })

    inspected = inspect(row.raw_payload)
    assert inspected =~ "[REDACTED]"
    refute inspected =~ "secret-token"
    refute inspected =~ "secret-cookie"
  end
end
