defmodule SymphonyElixir.LinearPaginationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Issue, Pagination}

  test "decodes a paginated issue response with page cursor metadata" do
    body = %{
      "data" => %{
        "issues" => %{
          "nodes" => [
            %{"id" => "issue-1", "identifier" => "MT-1"},
            :malformed
          ],
          "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
        }
      }
    }

    assert {:ok, [%Issue{id: "issue-1"}], %{has_next_page: true, end_cursor: "cursor-2"}} =
             Pagination.decode_page_response(body, nil)
  end

  test "returns graphql and unknown-payload errors without transport setup" do
    errors = [%{"message" => "bad query"}]

    assert Pagination.decode_response(%{"errors" => errors}, nil) == {:error, {:linear_graphql_errors, errors}}
    assert Pagination.decode_response(%{"data" => %{}}, nil) == {:error, :linear_unknown_payload}
  end

  test "requires an end cursor when Linear reports another page" do
    assert Pagination.next_page_cursor(%{has_next_page: true, end_cursor: "cursor-2"}) == {:ok, "cursor-2"}
    assert Pagination.next_page_cursor(%{has_next_page: true, end_cursor: ""}) == {:error, :linear_missing_end_cursor}
    assert Pagination.next_page_cursor(%{has_next_page: false, end_cursor: nil}) == :done
  end

  test "merges pages and restores requested issue id ordering" do
    page_1 = [%Issue{id: "issue-1", identifier: "MT-1"}]
    page_2 = [%Issue{id: "issue-3", identifier: "MT-3"}, %Issue{id: "issue-2", identifier: "MT-2"}]

    merged = Pagination.merge_issue_pages([page_1, page_2])
    order_index = Pagination.issue_order_index(["issue-2", "issue-1"])

    assert Enum.map(merged, & &1.id) == ["issue-1", "issue-3", "issue-2"]
    assert Enum.map(Pagination.sort_issues_by_requested_ids(merged, order_index), & &1.id) == ["issue-2", "issue-1", "issue-3"]
  end
end
