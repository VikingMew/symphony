defmodule SymphonyElixir.ImplementationHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue

  test "completion prepares the PR before Linear writes and moves state last" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    {:ok, order} = Agent.start_link(fn -> [] end)
    test_pid = self()

    response =
      DynamicTool.execute("linear_task_update", completion_payload(),
        issue: issue(),
        profile: "implementation",
        session_id: "thread-1-turn-1",
        implementation_handoff_preparer: fn handoff_issue, handoff_opts ->
          Agent.update(order, &[{:pr, handoff_issue.branch_name} | &1])
          refute Keyword.has_key?(handoff_opts, :workspace)
          {:ok, pull_request()}
        end,
        implementation_handoff_observer: fn status, _issue, details, opts ->
          send(test_pid, {:handoff_observed, status, details, Keyword.get(opts, :session_id)})
        end,
        graphql: graphql_recorder(order)
      )

    assert response["success"]
    output = Jason.decode!(response["output"])
    assert output["handoff"]["url"] == "https://github.com/acme/app/pull/12"
    assert output["requested_state"] == "Ready to Merge"

    assert Enum.reverse(Agent.get(order, & &1)) == [
             {:pr, "feature/sym-1"},
             {:attachment, "https://github.com/acme/app/tree/feature/sym-1"},
             {:attachment, "https://github.com/acme/app/pull/12"},
             :comment,
             :state_lookup,
             {:state_update, "state-ready-to-merge"}
           ]

    assert_received {:handoff_observed, :completed, %{url: "https://github.com/acme/app/pull/12"}, "thread-1-turn-1"}
  end

  test "PR failure leaves Linear untouched and is visible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    response =
      DynamicTool.execute("linear_task_update", completion_payload(),
        issue: issue(),
        profile: "implementation",
        implementation_handoff_preparer: fn _issue, _opts ->
          {:error, {:implementation_handoff_failed, {:remote_branch_not_found, "feature/sym-1"}}}
        end,
        graphql: fn _query, _variables -> flunk("Linear must not be called before PR success") end
      )

    refute response["success"]
    assert response["output"] =~ "remote_branch_not_found"
  end

  test "Linear transition failure is typed and marks the prepared handoff failed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    test_pid = self()

    graphql = fn query, variables ->
      cond do
        query =~ "attachmentCreate" ->
          {:ok, %{"data" => %{"attachmentCreate" => %{"success" => true}}}}

        query =~ "commentCreate" ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        query =~ "SymphonyLinearIssueTeamStates" ->
          {:ok, team_states_response()}

        query =~ "SymphonyLinearTaskIssueUpdate" ->
          assert variables["input"]["stateId"] == "state-ready-to-merge"
          {:ok, %{"errors" => [%{"message" => "transition denied"}]}}
      end
    end

    response =
      DynamicTool.execute("linear_task_update", completion_payload(),
        issue: issue(),
        profile: "implementation",
        implementation_handoff_preparer: fn _issue, _opts -> {:ok, pull_request()} end,
        implementation_handoff_observer: fn status, _issue, details, _opts ->
          send(test_pid, {:handoff_observed, status, details})
        end,
        graphql: graphql
      )

    refute response["success"]
    assert response["output"] =~ "linear_issue_update_failed"
    assert_received {:handoff_observed, :failed, %{reason: reason}}
    assert reason =~ "transition denied"
  end

  test "completion requires the AgentRunner-owned handoff and final handoff fields" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    unavailable =
      DynamicTool.execute("linear_task_update", completion_payload(),
        issue: issue(),
        profile: "implementation"
      )

    refute unavailable["success"]
    assert unavailable["output"] =~ "implementation_handoff_unavailable"

    Enum.each(["comment", "result", "references"], fn field ->
      payload = Map.delete(completion_payload(), field)

      response =
        DynamicTool.execute("linear_task_update", payload,
          issue: issue(),
          profile: "implementation"
        )

      refute response["success"]
      assert response["output"] =~ "implementation_handoff_field_required"
      assert response["output"] =~ field
    end)
  end

  test "handoff does not depend on a local or SSH worker workspace path" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    for workspace <- [nil, "/remote/worker/not-mounted-on-symphony/SYM-1"] do
      opts =
        [
          issue: issue(),
          profile: "implementation",
          implementation_handoff_preparer: fn _issue, handoff_opts ->
            assert Keyword.get(handoff_opts, :workspace) == workspace
            {:ok, pull_request()}
          end,
          graphql: graphql_recorder(nil)
        ]
        |> maybe_put_workspace(workspace)

      assert DynamicTool.execute("linear_task_update", completion_payload(), opts)["success"]
    end
  end

  defp completion_payload do
    %{
      "target_state" => "Ready to Merge",
      "comment" => "Completed: handoff\nValidation: green\nDeviations: None\nBlockers: None",
      "result" => %{
        "completed" => "handoff",
        "validation" => "green",
        "deviations" => "None",
        "blockers" => "None"
      },
      "references" => %{
        "branch_url" => "https://github.com/acme/app/tree/feature/sym-1",
        "branch" => "feature/sym-1"
      }
    }
  end

  defp issue do
    %Issue{
      id: "issue-1",
      identifier: "SYM-1",
      title: "Ship PR handoff",
      state: "In Progress",
      branch_name: "feature/sym-1"
    }
  end

  defp pull_request do
    %{
      url: "https://github.com/acme/app/pull/12",
      repository: "acme/app",
      base: "main",
      head: "feature/sym-1",
      source: :gh
    }
  end

  defp graphql_recorder(order) do
    fn query, variables ->
      cond do
        query =~ "attachmentCreate" ->
          record(order, {:attachment, variables["input"]["url"]})

          {:ok,
           %{
             "data" => %{
               "attachmentCreate" => %{
                 "success" => true,
                 "attachment" => %{"id" => "attachment", "title" => variables["input"]["title"]}
               }
             }
           }}

        query =~ "commentCreate" ->
          record(order, :comment)
          assert variables["body"] =~ "https://github.com/acme/app/pull/12"
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        query =~ "SymphonyLinearIssueTeamStates" ->
          record(order, :state_lookup)
          {:ok, team_states_response()}

        query =~ "SymphonyLinearTaskIssueUpdate" ->
          record(order, {:state_update, variables["input"]["stateId"]})
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  defp team_states_response do
    %{
      "data" => %{
        "issue" => %{
          "team" => %{
            "states" => %{
              "nodes" => [
                %{"id" => "state-ready-to-merge", "name" => "Ready to Merge"}
              ]
            }
          }
        }
      }
    }
  end

  defp record(nil, _event), do: :ok
  defp record(order, event), do: Agent.update(order, &[event | &1])

  defp maybe_put_workspace(opts, nil), do: opts
  defp maybe_put_workspace(opts, workspace), do: Keyword.put(opts, :workspace, workspace)
end
