defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Issue

  test "tool_specs advertises restricted task and pull request tools" do
    specs = DynamicTool.tool_specs()
    assert %{"inputSchema" => %{"type" => "object", "properties" => read_props}} = Enum.find(specs, &(&1["name"] == "linear_task_read"))
    assert %{"inputSchema" => %{"type" => "object", "properties" => update_props}} = Enum.find(specs, &(&1["name"] == "linear_task_update"))
    assert %{"inputSchema" => %{"type" => "object", "properties" => create_props}} = Enum.find(specs, &(&1["name"] == "linear_issue_create"))

    assert %{"inputSchema" => %{"required" => ["title", "body"]}} =
             Enum.find(specs, &(&1["name"] == "create_pull_request"))

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
               "supportedTools" => [
                 "linear_task_read",
                 "linear_task_update",
                 "linear_issue_create",
                 "create_pull_request",
                 "handoff"
               ]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "create_pull_request is restricted to implementation and passes Codex content to the backend" do
    issue = %Issue{id: "issue-1", identifier: "SYM-1", branch_name: "feature/sym-1"}
    payload = %{"title" => "SYM-1: Ship", "body" => "#### Summary\n\n- shipped\n\nFixes SYM-1"}

    response =
      DynamicTool.execute("create_pull_request", payload,
        issue: issue,
        profile: "implementation",
        session_id: "thread-1-turn-1",
        pull_request_proof_secret: "proof-secret",
        pull_request_creator: fn ^issue, rendered, _opts ->
          assert rendered == %{title: payload["title"], body: payload["body"]}
          {:ok, %{url: "https://github.com/acme/app/pull/1"}}
        end
      )

    assert response["success"]
    assert Jason.decode!(response["output"])["url"] == "https://github.com/acme/app/pull/1"
    assert is_binary(Jason.decode!(response["output"])["completion_proof"])

    rejected =
      DynamicTool.execute("create_pull_request", payload,
        issue: issue,
        profile: "refinement",
        session_id: "thread-1-turn-2",
        pull_request_proof_secret: "proof-secret"
      )

    refute rejected["success"]
    assert rejected["output"] =~ "not allowed"
  end

  test "handoff accepts only the pull request created by the current session" do
    created = %{url: "https://github.com/acme/app/pull/1", completion_proof: "session-proof"}

    payload = %{
      "comment" => "  Shipped and verified.  ",
      "result" => %{"outcome" => "shipped", "validation" => "make all"},
      "references" => %{
        "branch" => " feature/sym-1 ",
        "commit" => " abc123 ",
        "pr_url" => created.url,
        "pr_proof" => created.completion_proof
      }
    }

    response =
      DynamicTool.execute("handoff", payload,
        profile: "implementation",
        pull_request_result: fn -> created end,
        handoff_submitter: fn submitted ->
          send(self(), {:handoff, submitted})
          :ok
        end
      )

    assert response["success"]
    assert Jason.decode!(response["output"]) == %{"accepted" => true, "linear_updated" => false}
    assert_receive {:handoff, submitted}
    assert submitted["comment"] == "Shipped and verified."
    assert submitted["references"]["branch"] == "feature/sym-1"
    assert submitted["references"]["commit"] == "abc123"

    mismatched = put_in(payload, ["references", "pr_proof"], "other-proof")
    rejected = DynamicTool.execute("handoff", mismatched, profile: "implementation", pull_request_result: fn -> created end)
    refute rejected["success"]
    assert rejected["output"] =~ "create_pull_request"
  end

  test "handoff reports stable field paths for missing and empty values" do
    valid = %{
      "comment" => "done",
      "result" => %{"validation" => "green"},
      "references" => %{
        "branch" => "feature/sym-1",
        "commit" => "abc123",
        "pr_url" => "https://github.com/acme/app/pull/1",
        "pr_proof" => "proof"
      }
    }

    cases = [
      {Map.delete(valid, "comment"), "handoff.comment"},
      {Map.put(valid, "comment", "  "), "handoff.comment"},
      {Map.delete(valid, "result"), "handoff.result"},
      {Map.put(valid, "result", %{}), "handoff.result"},
      {Map.delete(valid, "references"), "handoff.references"},
      {put_in(valid, ["references", "branch"], ""), "handoff.references.branch"},
      {put_in(valid, ["references", "commit"], ""), "handoff.references.commit"},
      {Map.put(valid, "references", Map.delete(valid["references"], "pr_url")), "handoff.references.pr_url"},
      {Map.put(valid, "references", Map.delete(valid["references"], "pr_proof")), "handoff.references.pr_proof"}
    ]

    for {payload, field} <- cases do
      response = DynamicTool.execute("handoff", payload, profile: "implementation")
      refute response["success"]
      assert response["output"] =~ field
    end

    rejected = DynamicTool.execute("handoff", valid, profile: "refinement")
    refute rejected["success"]
    assert rejected["output"] =~ "only available to implementation"
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

  test "restricted Linear tool calls persist structured success audit events" do
    payload = %{
      "title" => "Code/doc drift",
      "problem" => "Docs mention a missing surface.",
      "evidence" => "README says X but code exposes Y.",
      "why_it_matters" => "Operators get wrong guidance.",
      "suggested_direction" => "Align docs with runtime.",
      "category" => "documentation drift",
      "source_run_id" => "run-operator"
    }

    response =
      DynamicTool.execute("linear_issue_create", payload,
        profile: "nap",
        run_id: "run-operator",
        operator_kind: "nap",
        session_id: "thread-1-turn-1",
        issue_creator: fn created_payload ->
          {:ok,
           %{
             "id" => "issue-created",
             "identifier" => "CCR-10",
             "title" => created_payload["title"],
             "url" => "https://linear.app/acme/issue/CCR-10",
             "state" => "Backlog"
           }}
        end
      )

    assert response["success"] == true

    [event] = FakePersistence.list_events(event_type: "linear.tool_call")
    assert event.run_id == "run-operator"
    assert event.payload.tool == "linear_issue_create"
    assert event.payload.status == "success"
    assert event.payload.profile == "nap"
    assert event.payload.operator_kind == "nap"
    assert event.payload.session_id == "thread-1-turn-1"
    assert event.payload.arguments["title"] == "Code/doc drift"
    assert event.payload.result["identifier"] == "CCR-10"
    assert event.payload.result["url"] == "https://linear.app/acme/issue/CCR-10"
  end

  test "restricted Linear tool calls persist structured failure audit events" do
    response =
      DynamicTool.execute("linear_issue_create", %{"title" => "Incomplete"},
        profile: "day_dreaming",
        run_id: "run-day-dreaming",
        operator_kind: "day_dreaming"
      )

    assert response["success"] == false

    [event] = FakePersistence.list_events(event_type: "linear.tool_call")
    assert event.run_id == "run-day-dreaming"
    assert event.payload.tool == "linear_issue_create"
    assert event.payload.status == "failure"
    assert event.payload.profile == "day_dreaming"
    assert event.payload.error.class == "validation_failed"
    assert event.payload.error.message =~ "requires non-empty"
    assert event.payload.arguments["title"] == "Incomplete"
  end

  test "missing workflow profile is captured as a stable Linear tool failure class" do
    payload = %{
      "title" => "Profile missing",
      "problem" => "Synthetic operator state cannot resolve a workflow profile.",
      "evidence" => "The issue state is Nap.",
      "why_it_matters" => "Tool policy cannot decide whether creation is allowed.",
      "suggested_direction" => "Pass explicit operator profile.",
      "category" => "runtime"
    }

    response =
      DynamicTool.execute("linear_issue_create", payload,
        run_id: "run-missing-profile",
        operator_kind: "nap",
        issue: %Issue{id: "operator-nap", identifier: "NAP-1", state: "Nap"}
      )

    assert response["success"] == false

    [event] = FakePersistence.list_events(event_type: "linear.tool_call")
    assert event.run_id == "run-missing-profile"
    assert event.issue_identifier == "NAP-1"
    assert event.payload.error.class == "workflow_profile_unavailable"
    assert event.payload.error.message == "Workflow profile is unavailable for this Codex session."
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
          "target_state" => "Ready to Merge",
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
                       "target_state" => "Ready to Merge",
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
