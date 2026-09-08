defmodule SymphonyElixir.PRReview.QueueTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, PRReview.Queue}

  setup do
    previous_panel = Application.fetch_env!(:symphony_elixir, :panel)

    on_exit(fn -> Application.put_env(:symphony_elixir, :panel, previous_panel) end)

    :ok
  end

  test "dispatch uses deployment review capacity without project context" do
    put_panel_capacity(10, 2)
    state = queue_state(2)

    assert Process.get(:symphony_workflow_context) == nil
    assert Config.panel_max_concurrent_reviews() == 2
    assert {:noreply, ^state} = Queue.handle_cast(:wake, state)
  end

  test "dispatch caps review capacity at deployment agent capacity" do
    put_panel_capacity(2, 5)
    state = queue_state(2)

    assert Config.panel_max_concurrent_agents() == 2
    assert Config.panel_max_concurrent_reviews() == 5
    assert {:noreply, ^state} = Queue.handle_cast(:wake, state)
  end

  defp put_panel_capacity(agent_capacity, review_capacity) do
    panel = Application.fetch_env!(:symphony_elixir, :panel)

    Application.put_env(
      :symphony_elixir,
      :panel,
      panel
      |> Keyword.put(:max_concurrent_agents, agent_capacity)
      |> Keyword.put(:max_concurrent_reviews, review_capacity)
    )
  end

  defp queue_state(running_count) do
    running = Map.new(1..running_count, fn index -> {make_ref(), "review-#{index}"} end)
    %{running: running, opts: []}
  end
end
