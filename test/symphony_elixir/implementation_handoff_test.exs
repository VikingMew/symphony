defmodule SymphonyElixir.ImplementationHandoffTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue

  @proof_secret "proof-secret"
  @session_id "thread-1-turn-1"

  test "Codex creates the PR before Linear writes and moves state last" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    {:ok, order} = Agent.start_link(fn -> [] end)

    pr_response =
      DynamicTool.execute("create_pull_request", pull_request_payload(),
        issue: issue(),
        profile: "implementation",
        session_id: @session_id,
        pull_request_proof_secret: @proof_secret,
        pull_request_creator: fn handoff_issue, rendered, handoff_opts ->
          Agent.update(order, &[{:pr, handoff_issue.branch_name} | &1])
          assert rendered.body =~ "Fixes SYM-1"
          refute Keyword.has_key?(handoff_opts, :workspace)
          {:ok, pull_request()}
        end,
        graphql: graphql_recorder(order)
      )

    assert pr_response["success"]

    response =
      DynamicTool.execute("linear_task_update", completion_payload(),
        issue: issue(),
        profile: "implementation",
        session_id: @session_id,
        pull_request_proof_secret: @proof_secret,
        graphql: graphql_recorder(order)
      )

    assert response["success"]
    output = Jason.decode!(response["output"])
    assert output["requested_state"] == "Ready to Merge"

    assert Enum.reverse(Agent.get(order, & &1)) == [
             {:pr, "feature/sym-1"},
             {:attachment, "https://github.com/acme/app/tree/feature/sym-1"},
             {:attachment, "https://github.com/acme/app/pull/12"},
             :comment,
             :state_lookup,
             {:state_update, "state-ready-to-merge"}
           ]
  end

  test "PR failure leaves Linear untouched and is visible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

    response =
      DynamicTool.execute("create_pull_request", pull_request_payload(),
        issue: issue(),
        profile: "implementation",
        session_id: @session_id,
        pull_request_proof_secret: @proof_secret,
        pull_request_creator: fn _issue, _payload, _opts ->
          {:error, {:implementation_handoff_failed, {:remote_branch_not_found, "feature/sym-1"}}}
        end,
        graphql: fn _query, _variables -> flunk("Linear must not be called before PR success") end
      )

    refute response["success"]
    assert response["output"] =~ "remote_branch_not_found"
  end

  test "Linear transition failure is typed after PR creation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

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

    assert DynamicTool.execute("create_pull_request", pull_request_payload(),
             issue: issue(),
             profile: "implementation",
             session_id: @session_id,
             pull_request_proof_secret: @proof_secret,
             pull_request_creator: fn _issue, _rendered, _opts -> {:ok, pull_request()} end
           )["success"]

    response =
      DynamicTool.execute("linear_task_update", completion_payload(),
        issue: issue(),
        profile: "implementation",
        session_id: @session_id,
        pull_request_proof_secret: @proof_secret,
        graphql: graphql
      )

    refute response["success"]
    assert response["output"] =~ "linear_issue_update_failed"
  end

  test "completion requires final handoff fields including the PR URL" do
    write_workflow_file!(Workflow.workflow_file_path(),
      project_repository_url: "https://github.com/acme/app"
    )

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

    missing_url = put_in(completion_payload(), ["references"], %{"branch" => "feature/sym-1"})
    response = DynamicTool.execute("linear_task_update", missing_url, issue: issue(), profile: "implementation")
    refute response["success"]
    assert response["output"] =~ "references.pr_url"

    forged = put_in(completion_payload(), ["references", "pr_proof"], "forged")

    response =
      DynamicTool.execute("linear_task_update", forged,
        issue: issue(),
        profile: "implementation",
        session_id: @session_id,
        pull_request_proof_secret: @proof_secret,
        graphql: fn _query, _variables -> flunk("forged proof must fail before Linear writes") end
      )

    refute response["success"]
    assert response["output"] =~ "create_pull_request"
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
          session_id: @session_id,
          pull_request_proof_secret: @proof_secret,
          pull_request_creator: fn _issue, _payload, handoff_opts ->
            assert Keyword.get(handoff_opts, :workspace) == workspace
            {:ok, pull_request()}
          end,
          graphql: graphql_recorder(nil)
        ]
        |> maybe_put_workspace(workspace)

      assert DynamicTool.execute("create_pull_request", pull_request_payload(), opts)["success"]
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
        "branch" => "feature/sym-1",
        "pr_url" => "https://github.com/acme/app/pull/12",
        "pr_proof" => pull_request_proof()
      }
    }
  end

  defp pull_request_payload do
    %{
      "title" => "SYM-1: Ship PR handoff",
      "body" => "#### Summary\n\n- handoff\n\n#### Test Plan\n\n- [x] green\n\nFixes SYM-1"
    }
  end

  defp pull_request_proof do
    :crypto.mac(
      :hmac,
      :sha256,
      @proof_secret,
      @session_id <> <<0>> <> "https://github.com/acme/app/pull/12"
    )
    |> Base.url_encode64(padding: false)
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
