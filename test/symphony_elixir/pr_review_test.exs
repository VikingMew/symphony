defmodule SymphonyElixir.PRReviewTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Codex.DynamicTool, Linear.Issue, PRReview, PRReview.Runner}

  @head String.duplicate("a", 40)

  test "review profile exposes only context read and typed result submission" do
    assert Enum.map(DynamicTool.tool_specs("review"), & &1["name"]) == [
             "review_context_read",
             "submit_review"
           ]

    refute Enum.any?(
             DynamicTool.tool_specs("review"),
             &(&1["name"] in [
                 "linear_task_update",
                 "create_pull_request",
                 "handoff"
               ])
           )

    assert DynamicTool.execute("review_context_read", %{},
             profile: "review",
             review_context: %{"head_oid" => @head}
           )["success"]

    assert DynamicTool.execute(
             "submit_review",
             %{
               "outcome" => "approve",
               "head_sha" => @head,
               "summary" => "Acceptance criteria and evidence match.",
               "findings" => []
             },
             profile: "review",
             review_head_oid: @head,
             review_submitter: fn result ->
               send(self(), {:result, result})
               :ok
             end
           )["success"]

    assert_receive {:result, %{outcome: :approve, head_sha: @head}}
  end

  test "review result cannot claim a different head" do
    response =
      DynamicTool.execute(
        "submit_review",
        %{
          "outcome" => "findings",
          "head_sha" => String.duplicate("b", 40),
          "summary" => "Mismatch",
          "findings" => ["Fix it"]
        },
        profile: "review",
        review_head_oid: @head,
        review_submitter: fn _ -> flunk("mismatched result must not be accepted") end
      )

    refute response["success"]
  end

  test "runner revalidates state and immutable head before starting Codex" do
    job = job()
    issue = %Issue{id: "linear-1", identifier: "SYM-26", state: "Ready to Merge"}

    context_loader = fn ^job, [] ->
      {:ok,
       %{
         "head_oid" => @head,
         "base_oid" => String.duplicate("b", 40),
         "pull_request" => %{"state" => "OPEN", "body" => "tests"},
         "diff" => "diff --git"
       }}
    end

    app_server = fn workspace, prompt, ^issue, opts ->
      assert String.contains?(workspace, "/.reviews/review-1")
      assert prompt =~ @head
      assert opts[:profile] == "review"
      assert opts[:thread_sandbox] == "read-only"
      assert opts[:turn_sandbox_policy] == %{"type" => "readOnly", "networkAccess" => false}
      {:ok, %{review_result: %{outcome: :approve, head_sha: @head, summary: "OK", findings: []}}}
    end

    assert {:ok, %{outcome: :approve}} =
             Runner.run(job,
               workspace_root: System.tmp_dir!(),
               state_fetcher: fn ["linear-1"] -> {:ok, [issue]} end,
               issue_context_loader: fn "linear-1" -> {:ok, %{"description" => "criteria", "comments" => %{"nodes" => []}}} end,
               context_loader: context_loader,
               app_server: app_server
             )

    assert {:superseded, :pull_request_head_or_state_changed} =
             Runner.run(job,
               state_fetcher: fn ["linear-1"] -> {:ok, [issue]} end,
               issue_context_loader: fn "linear-1" -> {:ok, %{}} end,
               context_loader: fn ^job, [] ->
                 {:ok,
                  %{
                    "head_oid" => String.duplicate("c", 40),
                    "pull_request" => %{"state" => "OPEN"}
                  }}
               end,
               app_server: fn _, _, _, _ -> flunk("stale head must not start Codex") end
             )
  end

  test "runner supersedes jobs whose issue is absent or no longer ready" do
    assert {:superseded, :issue_missing} =
             Runner.run(job(), state_fetcher: fn ["linear-1"] -> {:ok, []} end)

    assert {:superseded, :issue_not_ready_to_merge} =
             Runner.run(job(),
               state_fetcher: fn ["linear-1"] ->
                 {:ok, [%Issue{id: "linear-1", identifier: "SYM-26", state: "In Progress"}]}
               end
             )
  end

  test "stable comments include reviewed head and actionable findings" do
    assert PRReview.comment(%{outcome: :approve, head_sha: @head, summary: "Ready"}) ==
             "Symphony PR review: APPROVE (head #{@head})\nReady"

    result = %{outcome: :findings, head_sha: @head, summary: "Changes required", findings: ["Add retry coverage"]}
    assert PRReview.comment(result) == "Symphony PR review: FINDINGS (head #{@head})\nChanges required\n\n1. Add retry coverage"
  end

  test "review result normalization accepts wire values and rejects malformed findings" do
    assert {:ok, %{outcome: :approve, head_sha: @head, findings: []}} =
             PRReview.normalize(%{
               "outcome" => :approve,
               "head_sha" => @head,
               "summary" => "Ready"
             })

    assert {:error, :invalid_findings} =
             PRReview.normalize(%{
               outcome: :findings,
               head_sha: @head,
               summary: "Broken",
               findings: [:not_text]
             })

    assert {:error, :invalid_review_result} = PRReview.normalize(%{})
  end

  defp job do
    %{
      id: "review-1",
      run_id: "run-1",
      project_id: "project-1",
      tracker_issue_id: "linear-1",
      issue_identifier: "SYM-26",
      pr_url: "https://github.com/acme/app/pull/1",
      repository: "acme/app",
      head_oid: @head
    }
  end
end
