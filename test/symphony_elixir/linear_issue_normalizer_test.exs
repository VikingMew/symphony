defmodule SymphonyElixir.LinearIssueNormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.IssueNormalizer

  test "normalizes labels blockers dates priority and assignee routing" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{"id" => "user-1"},
      "labels" => %{"nodes" => [%{"name" => "Backend"}, :bad_label]},
      "inverseRelations" => %{
        "nodes" => [
          %{"type" => "blocks", "issue" => %{"id" => "issue-2", "identifier" => "MT-2", "state" => %{"name" => "In Progress"}}},
          %{"type" => "relatesTo", "issue" => %{"id" => "issue-3"}}
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "bad timestamp"
    }

    {:ok, assignee_filter} = IssueNormalizer.build_assignee_filter("user-1")

    issue = IssueNormalizer.normalize_issue(raw_issue, assignee_filter)

    assert issue.id == "issue-1"
    assert issue.identifier == "MT-1"
    assert issue.priority == 2
    assert issue.labels == ["backend"]
    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
    assert %DateTime{} = issue.created_at
    assert issue.updated_at == nil
  end

  test "marks mismatched or missing assignees as not assigned when a filter exists" do
    {:ok, assignee_filter} = IssueNormalizer.build_assignee_filter("user-1")

    refute IssueNormalizer.normalize_issue(%{"assignee" => %{"id" => "user-2"}}, assignee_filter).assigned_to_worker
    refute IssueNormalizer.normalize_issue(%{"assignee" => nil}, assignee_filter).assigned_to_worker
  end

  test "blank assignee filter routes every normalized issue and me requests viewer resolution" do
    assert IssueNormalizer.build_assignee_filter(" ") == {:ok, nil}
    assert IssueNormalizer.build_assignee_filter("me") == {:viewer, "me"}
    assert IssueNormalizer.normalize_issue(%{"assignee" => nil}).assigned_to_worker
  end

  test "ignores malformed issue payloads" do
    assert IssueNormalizer.normalize_issue(:not_a_map) == nil
  end
end
