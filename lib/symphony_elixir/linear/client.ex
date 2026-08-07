defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, RuntimeProxy}
  alias SymphonyElixir.Linear.{Issue, IssueNormalizer, Pagination}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @workflow_state_create_mutation """
  mutation SymphonyLinearWorkflowStateCreate($input: WorkflowStateCreateInput!) {
    workflowStateCreate(input: $input) {
      success
      workflowState {
        id
        name
        type
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @doc """
  Fetches issue state snapshots using an injected GraphQL function.

  This public boundary is useful for alternate clients and focused tests that
  need the same pagination/normalization logic without making network calls.
  """
  @spec fetch_issue_states_by_ids([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] -> {:ok, []}
      ids -> do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    tracker = Config.settings!().tracker

    graphql_with_auth(query, variables, tracker.api_key, tracker.endpoint, opts)
  end

  @spec graphql_with_auth(String.t(), map(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def graphql_with_auth(query, variables, api_key, endpoint, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, fn request_payload, headers -> post_graphql_request(request_payload, headers, endpoint) end)

    with {:ok, headers} <- graphql_headers(api_key),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status, sanitized_error_body(response.body)}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @spec create_workflow_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_workflow_state(team_id, name, opts \\ []) when is_binary(team_id) and is_binary(name) and is_list(opts) do
    input =
      %{
        "teamId" => team_id,
        "name" => name,
        "type" => Keyword.get(opts, :type, "started")
      }
      |> maybe_put_optional("description", Keyword.get(opts, :description))
      |> maybe_put_optional("color", Keyword.get(opts, :color))

    case graphql(@workflow_state_create_mutation, %{"input" => input}, operation_name: "SymphonyLinearWorkflowStateCreate") do
      {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => true} = payload}}} ->
        {:ok, payload}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, payload} ->
        {:error, {:unexpected_workflow_state_create_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- Pagination.decode_page_response(body, assignee_filter) do
      updated_acc = Pagination.prepend_page_issues(issues, acc_issues)

      case Pagination.next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, Pagination.finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = Pagination.issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> Pagination.finalize_paginated_issues()
    |> Pagination.sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- Pagination.decode_response(body, assignee_filter) do
          updated_acc = Pagination.prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp sanitized_error_body(body) do
    body
    |> sanitize_error_body()
    |> truncate_error_body_value()
  end

  defp sanitize_error_body(%{"errors" => errors} = body) when is_list(errors) do
    body
    |> Map.take(["errors"])
    |> Map.put("errors", Enum.map(errors, &sanitize_graphql_error/1))
  end

  defp sanitize_error_body(body) when is_map(body) do
    body
    |> Map.take(["code", "error", "errors", "extensions", "locations", "message", "path"])
    |> Enum.into(%{}, fn {key, value} -> {key, sanitize_error_body(value)} end)
  end

  defp sanitize_error_body(body) when is_list(body), do: Enum.map(body, &sanitize_error_body/1)

  defp sanitize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/(Authorization|api[_-]?key|token)(["':=>,\s]+)[^,\]\}\s]+/i, "\\1\\2[REDACTED]")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_error_body(body), do: body

  defp sanitize_graphql_error(error) when is_map(error) do
    error
    |> Map.take(["message", "extensions", "locations", "path"])
    |> sanitize_error_body()
  end

  defp sanitize_graphql_error(error), do: sanitize_error_body(error)

  defp truncate_error_body_value(value) when is_binary(value), do: truncate_error_body(value)

  defp truncate_error_body_value(value) do
    encoded = inspect(value, limit: 20, printable_limit: @max_error_body_log_bytes)

    if byte_size(encoded) > @max_error_body_log_bytes do
      encoded
      |> binary_part(0, @max_error_body_log_bytes)
      |> Kernel.<>("<truncated>")
    else
      value
    end
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(api_key) do
    case api_key do
      token when is_binary(token) and token != "" ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}

      _ ->
        {:error, :missing_linear_api_token}
    end
  end

  defp post_graphql_request(payload, headers, endpoint) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: request_options(endpoint)
    )
  end

  @doc """
  Returns Req connection options for a Linear endpoint, including runtime proxy settings.
  """
  @spec request_options(String.t()) :: keyword()
  def request_options(endpoint) when is_binary(endpoint) do
    RuntimeProxy.connect_options(endpoint, timeout: 30_000)
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case IssueNormalizer.build_assignee_filter(assignee) do
      {:viewer, _configured_assignee} -> resolve_viewer_assignee_filter()
      result -> result
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case IssueNormalizer.assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_optional(map, _key, nil), do: map
  defp maybe_put_optional(map, _key, ""), do: map
  defp maybe_put_optional(map, key, value), do: Map.put(map, key, value)
end
