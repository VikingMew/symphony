defmodule SymphonyElixir.ReleaseLegacyWorkflowTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Release.LegacyWorkflowCommand

  test "status formatter reports zero and convergence" do
    assert LegacyWorkflowCommand.format_status(:zero) ==
             "legacy instance workflow status: zero"

    assert LegacyWorkflowCommand.format_status({:converged, %{config: %{}, prompt_body: ""}}) ==
             "legacy instance workflow status: converged"
  end

  test "status formatter reports conflict paths and exact stored contributors" do
    conflict = %{
      "candidates" => [
        %{"project_id" => "project-a", "project_slug" => "alpha", "candidate" => %{}},
        %{"project_id" => "project-b", "project_slug" => "beta", "candidate" => %{}}
      ],
      "differing_paths" => [
        %{"path" => "codex.model", "contributors" => []},
        %{"path" => "prompt_body", "contributors" => []}
      ]
    }

    output = LegacyWorkflowCommand.format_status({:conflict, conflict})

    assert output ==
             "legacy instance workflow status: conflict\n" <>
               "path: codex.model\n" <>
               "path: prompt_body\n" <>
               "project: id=project-a slug=alpha\n" <>
               "project: id=project-b slug=beta"
  end

  test "status-only execution prints before returning and never reconciles" do
    assert {:ok, :zero} =
             LegacyWorkflowCommand.execute(
               :zero,
               nil,
               fn _slug -> flunk("status-only execution must not reconcile") end,
               fn output -> send(self(), {:output, output}) end
             )

    assert_receive {:output, "legacy instance workflow status: zero"}
  end

  test "an exact environment selection reconciles after conflict output" do
    conflict = conflict()
    parent = self()

    reconcile = fn slug ->
      send(parent, {:selected, slug})
      {:ok, {:converged, %{config: %{}, prompt_body: "Prompt"}}}
    end

    assert {:ok, {:converged, _instance}} =
             LegacyWorkflowCommand.execute(
               {:conflict, conflict},
               "beta",
               reconcile,
               fn output -> send(parent, {:output, output}) end
             )

    assert_receive {:output, output}
    assert output =~ "path: codex.model"
    assert output =~ "project: id=project-b slug=beta"
    assert_receive {:selected, "beta"}
    assert_receive {:output, "legacy instance workflow reconciliation: beta"}
  end

  test "unknown selection returns its typed error and remains retryable" do
    parent = self()

    reconcile = fn slug ->
      send(parent, {:attempt, slug})

      case slug do
        "beta" -> {:ok, {:converged, %{config: %{}, prompt_body: ""}}}
        unknown -> {:error, {:invalid_selection, unknown}}
      end
    end

    assert {:error, {:invalid_selection, "Beta"}} =
             LegacyWorkflowCommand.execute(
               {:conflict, conflict()},
               "Beta",
               reconcile,
               fn _output -> :ok end
             )

    assert {:ok, {:converged, _instance}} =
             LegacyWorkflowCommand.execute(
               {:conflict, conflict()},
               "beta",
               reconcile,
               fn _output -> :ok end
             )

    assert_receive {:attempt, "Beta"}
    assert_receive {:attempt, "beta"}
  end

  test "release database shell contains no cross-VM runtime publication call" do
    source = File.read!(Path.expand("../../lib/symphony_elixir/release.ex", __DIR__))
    assert String.contains?(source, "WorkflowStore.reconcile_legacy_instance_workflow/1")
    assert String.contains?(source, "force_reload") == false
  end

  defp conflict do
    %{
      "candidates" => [
        %{"project_id" => "project-a", "project_slug" => "alpha", "candidate" => %{}},
        %{"project_id" => "project-b", "project_slug" => "beta", "candidate" => %{}}
      ],
      "differing_paths" => [
        %{"path" => "codex.model", "contributors" => []},
        %{"path" => "prompt_body", "contributors" => []}
      ]
    }
  end
end
