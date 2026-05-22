defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue

  test "tool_specs advertises restricted Linear task tools" do
    specs = DynamicTool.tool_specs()
    assert %{"inputSchema" => %{"type" => "object", "properties" => read_props}} = Enum.find(specs, &(&1["name"] == "linear_task_read"))
    assert %{"inputSchema" => %{"type" => "object", "properties" => update_props}} = Enum.find(specs, &(&1["name"] == "linear_task_update"))
    assert %{"inputSchema" => %{"type" => "object", "properties" => create_props}} = Enum.find(specs, &(&1["name"] == "linear_issue_create"))

    assert Map.has_key?(read_props, "include_activity")
    assert Map.has_key?(read_props, "activity_limit")
    assert Map.has_key?(update_props, "comment")
    assert Map.has_key?(update_props, "target_state")
    assert Map.has_key?(create_props, "evidence")
    refute Enum.any?(DynamicTool.tool_specs(), &(&1["name"] == "linear_graphql"))
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_task_read", "linear_task_update", "linear_issue_create"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_issue_create is restricted to nap and day dreaming profiles" do
    payload = %{
      "title" => "Code/doc drift",
      "problem" => "Docs mention a missing surface.",
      "evidence" => "README says X but code exposes Y.",
      "why_it_matters" => "Operators get wrong guidance.",
      "suggested_direction" => "Align docs with runtime.",
      "category" => "documentation drift"
    }

    response =
      DynamicTool.execute("linear_issue_create", payload,
        profile: "nap",
        issue_creator: fn created_payload -> {:ok, Map.put(created_payload, "identifier", "CCR-10")} end
      )

    assert response["success"] == true
    assert Jason.decode!(response["output"])["identifier"] == "CCR-10"

    rejected =
      DynamicTool.execute("linear_issue_create", payload,
        profile: "implementation",
        issue_creator: fn _payload -> flunk("implementation profile must not create issues") end
      )

    assert rejected["success"] == false
    assert Jason.decode!(rejected["output"])["error"]["message"] =~ "not allowed"
  end

  test "linear_issue_create default path resolves project team backlog state and creates issue" do
    payload = %{
      "title" => "Add missing operator cue",
      "problem" => "The UI does not show the next action.",
      "evidence" => "Settings validation can fail without a nearby action.",
      "why_it_matters" => "Operators cannot recover quickly.",
      "suggested_direction" => "Show a targeted setup action.",
      "category" => "operator UX",
      "source_run_id" => "operator-nap-1"
    }

    response =
      DynamicTool.execute("linear_issue_create", payload,
        profile: "nap",
        graphql: fn query, variables ->
          cond do
            query =~ "SymphonyLinearIssueCreateContext" ->
              assert variables == %{"projectSlug" => "project"}

              {:ok,
               %{
                 "data" => %{
                   "projects" => %{
                     "nodes" => [
                       %{
                         "id" => "project-id",
                         "teams" => %{
                           "nodes" => [
                             %{"id" => "team-id", "states" => %{"nodes" => [%{"id" => "state-backlog", "name" => "Backlog"}]}}
                           ]
                         }
                       }
                     ]
                   }
                 }
               }}

            query =~ "SymphonyLinearIssueCreate" ->
              assert %{"input" => input} = variables
              assert input["projectId"] == "project-id"
              assert input["teamId"] == "team-id"
              assert input["stateId"] == "state-backlog"
              assert input["description"] =~ "Source run"

              {:ok,
               %{
                 "data" => %{
                   "issueCreate" => %{
                     "success" => true,
                     "issue" => %{
                       "id" => "issue-id",
                       "identifier" => "CCR-99",
                       "title" => payload["title"],
                       "url" => "https://linear.app/issue/CCR-99",
                       "state" => %{"name" => "Backlog"}
                     }
                   }
                 }
               }}
          end
        end
      )

    assert response["success"] == true

    assert Jason.decode!(response["output"]) == %{
             "id" => "issue-id",
             "identifier" => "CCR-99",
             "title" => payload["title"],
             "url" => "https://linear.app/issue/CCR-99",
             "state" => "Backlog"
           }
  end

  test "linear_task_read normalizes defaults and returns reader output" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_task_read",
        %{},
        task_reader: fn payload ->
          send(test_pid, {:task_reader_called, payload})
          {:ok, %{"issue" => %{"id" => "issue-1"}}}
        end
      )

    assert_received {:task_reader_called, %{"include_activity" => true, "activity_limit" => 50, "since" => nil}}
    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"issue" => %{"id" => "issue-1"}}
  end

  test "linear_task_read validates activity arguments" do
    response =
      DynamicTool.execute("linear_task_read", %{"include_activity" => "yes"}, task_reader: fn _payload -> flunk("reader should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "include_activity"

    response =
      DynamicTool.execute("linear_task_read", %{"activity_limit" => 101}, task_reader: fn _payload -> flunk("reader should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "activity_limit"
  end

  test "linear_task_update normalizes update payload and returns updater output" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_task_update",
        %{
          "comment" => "Ready for review",
          "target_state" => "In Review",
          "result" => %{"tests" => "green"}
        },
        task_updater: fn payload ->
          send(test_pid, {:task_updater_called, payload})
          {:ok, %{"ok" => true}}
        end
      )

    assert_received {:task_updater_called,
                     %{
                       "comment" => "Ready for review",
                       "target_state" => "In Review",
                       "result" => %{"tests" => "green"}
                     }}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"ok" => true}
  end

  test "linear_task_update rejects empty and invalid update payloads" do
    response =
      DynamicTool.execute("linear_task_update", %{}, task_updater: fn _payload -> flunk("updater should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "requires at least one"

    response =
      DynamicTool.execute("linear_task_update", %{"references" => ["bad"]}, task_updater: fn _payload -> flunk("updater should not be called") end)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "references"
  end

  test "linear_task_update reports unavailable default task context" do
    response = DynamicTool.execute("linear_task_update", %{"comment" => "hello"})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{"message" => "Linear task context is unavailable for this Codex session."}
           }
  end

  test "linear_task_update links concrete reference URLs to the current issue" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_task_update",
        %{
          "references" => %{
            "latest_human_comment_id" => "comment-1",
            "pr_url" => "https://github.com/acme/app/pull/12",
            "urls" => [
              "https://github.com/acme/app/pull/12",
              "https://github.com/acme/app/tree/codex/MT-1"
            ]
          },
          "result" => %{
            "commit_url" => "https://github.com/acme/app/commit/abc123",
            "commit" => "abc123"
          }
        },
        issue: %Issue{id: "issue-1"},
        profile: "implementation",
        graphql: fn query, variables ->
          cond do
            query =~ "attachmentCreate" ->
              send(test_pid, {:attachment_linked, variables["input"]})

              {:ok,
               %{
                 "data" => %{
                   "attachmentCreate" => %{
                     "success" => true,
                     "attachment" => %{
                       "id" => "attachment-#{System.unique_integer([:positive])}",
                       "title" => variables["input"]["title"]
                     }
                   }
                 }
               }}

            query =~ "commentCreate" ->
              {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-2"}}}}}

            true ->
              flunk("unexpected graphql call")
          end
        end
      )

    assert response["success"] == true

    assert_received {:attachment_linked,
                     %{
                       "issueId" => "issue-1",
                       "title" => "Pull Request",
                       "url" => "https://github.com/acme/app/pull/12"
                     }}

    assert_received {:attachment_linked,
                     %{
                       "issueId" => "issue-1",
                       "title" => "Reference",
                       "url" => "https://github.com/acme/app/tree/codex/MT-1"
                     }}

    assert_received {:attachment_linked,
                     %{
                       "issueId" => "issue-1",
                       "title" => "Commit",
                       "url" => "https://github.com/acme/app/commit/abc123"
                     }}

    refute_received {:attachment_linked, %{"url" => "abc123"}}

    output = Jason.decode!(response["output"])
    assert length(output["reference_links"]) == 3
    assert output["issue_update"] == nil
  end

  test "linear_task_update keeps non-url references as metadata without linking" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_task_update",
        %{"references" => %{"latest_human_comment_id" => "comment-1", "branch" => "codex/MT-1"}},
        issue: %Issue{id: "issue-1"},
        profile: "implementation",
        graphql: fn query, _variables ->
          if query =~ "attachmentCreate" do
            send(test_pid, :attachment_linked)
            flunk("attachment should not be linked")
          else
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "comment-2"}}}}}
          end
        end
      )

    assert response["success"] == true
    assert Jason.decode!(response["output"])["reference_links"] == []
    refute_received :attachment_linked
  end

  test "linear_task_update reports attachment link failures" do
    response =
      DynamicTool.execute(
        "linear_task_update",
        %{"references" => %{"pr_url" => "https://github.com/acme/app/pull/12"}},
        issue: %Issue{id: "issue-1"},
        profile: "implementation",
        graphql: fn _query, _variables ->
          {:ok, %{"errors" => [%{"message" => "attachment failed"}]}}
        end
      )

    assert response["success"] == false
    error = Jason.decode!(response["output"])["error"]
    assert error["message"] == "Restricted Linear task tool execution failed."
    assert error["reason"] =~ "linear_attachment_link_failed"
  end
end
