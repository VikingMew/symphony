defmodule SymphonyElixir.Linear.Pagination do
  @moduledoc """
  Pure Linear issue response decoding and pagination helpers.
  """

  alias SymphonyElixir.Linear.{Issue, IssueNormalizer}

  @spec decode_response(map(), map() | nil) :: {:ok, [Issue.t()]} | {:error, term()}
  def decode_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter)
      when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&IssueNormalizer.normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  def decode_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  def decode_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  @spec decode_page_response(map(), map() | nil) :: {:ok, [Issue.t()], map()} | {:ok, [Issue.t()]} | {:error, term()}
  def decode_page_response(
        %{
          "data" => %{
            "issues" => %{
              "nodes" => nodes,
              "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
            }
          }
        },
        assignee_filter
      )
      when is_list(nodes) do
    with {:ok, issues} <- decode_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  def decode_page_response(response, assignee_filter), do: decode_response(response, assignee_filter)

  @spec next_page_cursor(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
      when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  def next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  def next_page_cursor(_), do: :done

  @spec prepend_page_issues([Issue.t()], [Issue.t()]) :: [Issue.t()]
  def prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  @spec finalize_paginated_issues([Issue.t()]) :: [Issue.t()]
  def finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  @spec merge_issue_pages([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @spec issue_order_index([String.t()]) :: map()
  def issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  @spec sort_issues_by_requested_ids([Issue.t()], map()) :: [Issue.t()]
  def sort_issues_by_requested_ids(issues, issue_order_index)
      when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end
end
