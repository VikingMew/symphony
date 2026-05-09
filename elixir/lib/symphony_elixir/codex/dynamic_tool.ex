defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{BranchName, Config, Git, Linear.Client, Linear.Issue}

  @task_read_query """
  query SymphonyLinearTaskRead($id: String!, $commentFirst: Int!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      url
      branchName
      priority
      state {
        name
      }
      labels {
        nodes {
          name
        }
      }
      comments(first: $commentFirst) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user {
            name
          }
        }
      }
    }
  }
  """

  @issue_team_states_query """
  query SymphonyLinearIssueTeamStates($id: String!) {
    issue(id: $id) {
      team {
        states(first: 100) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """

  @issue_update_mutation """
  mutation SymphonyLinearTaskIssueUpdate($id: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $id, input: $input) {
      success
      issue {
        id
        identifier
        state {
          name
        }
        updatedAt
      }
    }
  }
  """

  @comment_create_mutation """
  mutation SymphonyLinearTaskCommentCreate($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        createdAt
      }
    }
  }
  """

  @attachment_create_mutation """
  mutation SymphonyLinearTaskAttachmentCreate($input: AttachmentCreateInput!) {
    attachmentCreate(input: $input) {
      success
      attachment {
        id
        title
      }
    }
  }
  """

  @read_tool "linear_task_read"
  @update_tool "linear_task_update"

  @read_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "include_activity" => %{
        "type" => "boolean",
        "description" => "Include recent comments and state-change activity needed to understand review feedback."
      },
      "activity_limit" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 100,
        "description" => "Maximum activity entries to include."
      },
      "since" => %{
        "type" => ["string", "null"],
        "description" => "Optional ISO-8601 lower bound for returned activity."
      }
    }
  }

  @update_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "description" => %{
        "type" => ["string", "null"],
        "description" => "Replacement task description. Only allowed by refinement profiles."
      },
      "comment" => %{
        "type" => ["string", "null"],
        "description" => "Comment to append to the task."
      },
      "target_state" => %{
        "type" => ["string", "null"],
        "description" => "Workflow state to request or transition to when allowed by the current profile."
      },
      "result" => %{
        "type" => ["object", "null"],
        "additionalProperties" => true,
        "description" => "Structured implementation or verification result for reviewer context."
      },
      "references" => %{
        "type" => ["object", "null"],
        "additionalProperties" => true,
        "description" => "Optional branch, commit, PR, or artifact references."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @read_tool ->
        execute_task_read(arguments, opts)

      @update_tool ->
        execute_task_update(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @read_tool,
        "description" => "Read the current Linear task detail and review activity through Symphony's restricted task API.",
        "inputSchema" => @read_schema
      },
      %{
        "name" => @update_tool,
        "description" => "Update the current Linear task through Symphony's restricted task API: description, comment, result, and allowed state transition.",
        "inputSchema" => @update_schema
      }
    ]
  end

  defp execute_task_read(arguments, opts) do
    reader = Keyword.get(opts, :task_reader, fn payload -> default_task_reader(payload, opts) end)

    with {:ok, payload} <- normalize_read_arguments(arguments),
         {:ok, result} <- reader.(payload) do
      success_response(result)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(@read_tool, reason))
    end
  end

  defp execute_task_update(arguments, opts) do
    updater = Keyword.get(opts, :task_updater, fn payload -> default_task_updater(payload, opts) end)

    with {:ok, payload} <- normalize_update_arguments(arguments),
         {:ok, result} <- updater.(payload) do
      success_response(result)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(@update_tool, reason))
    end
  end

  defp normalize_read_arguments(nil), do: {:ok, %{"include_activity" => true, "activity_limit" => 50}}

  defp normalize_read_arguments(arguments) when is_map(arguments) do
    include_activity = Map.get(arguments, "include_activity", Map.get(arguments, :include_activity, true))
    activity_limit = Map.get(arguments, "activity_limit", Map.get(arguments, :activity_limit, 50))
    since = Map.get(arguments, "since", Map.get(arguments, :since))

    cond do
      not is_boolean(include_activity) ->
        {:error, :invalid_include_activity}

      not is_integer(activity_limit) or activity_limit < 1 or activity_limit > 100 ->
        {:error, :invalid_activity_limit}

      not (is_nil(since) or is_binary(since)) ->
        {:error, :invalid_since}

      true ->
        {:ok,
         %{
           "include_activity" => include_activity,
           "activity_limit" => activity_limit,
           "since" => since
         }}
    end
  end

  defp normalize_read_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_update_arguments(arguments) when is_map(arguments) do
    payload =
      %{}
      |> put_optional_string(arguments, "description")
      |> put_optional_string(arguments, "comment")
      |> put_optional_string(arguments, "target_state")
      |> put_optional_map(arguments, "result")
      |> put_optional_map(arguments, "references")

    if map_size(payload) == 0 do
      {:error, :empty_update}
    else
      {:ok, payload}
    end
  catch
    {:invalid_field, field} -> {:error, {:invalid_field, field}}
  end

  defp normalize_update_arguments(_arguments), do: {:error, :invalid_arguments}

  defp put_optional_string(payload, arguments, field) do
    case Map.get(arguments, field, Map.get(arguments, String.to_atom(field))) do
      nil ->
        payload

      value when is_binary(value) ->
        Map.put(payload, field, value)

      _ ->
        throw({:invalid_field, field})
    end
  end

  defp put_optional_map(payload, arguments, field) do
    case Map.get(arguments, field, Map.get(arguments, String.to_atom(field))) do
      nil ->
        payload

      value when is_map(value) ->
        Map.put(payload, field, value)

      _ ->
        throw({:invalid_field, field})
    end
  end

  defp default_task_reader(payload, opts) do
    with {:ok, issue_id} <- issue_id_from_opts(opts),
         {:ok, profile} <- profile_from_opts(opts),
         {:ok, response} <-
           Client.graphql(@task_read_query, %{
             "id" => issue_id,
             "commentFirst" => Map.get(payload, "activity_limit", 50)
           }) do
      {:ok, normalize_task_read_response(response, Map.get(payload, "include_activity", true), profile)}
    end
  end

  defp default_task_updater(payload, opts) do
    with {:ok, issue_id} <- issue_id_from_opts(opts),
         {:ok, profile} <- profile_from_opts(opts),
         :ok <- validate_update_policy(payload, profile, opts),
         {:ok, issue_update} <- maybe_update_issue(issue_id, payload, opts),
         {:ok, reference_links} <- maybe_link_references(issue_id, payload, opts),
         {:ok, comment_update} <- maybe_create_comment(issue_id, payload, opts) do
      {:ok,
       %{
         "issue_update" => issue_update,
         "comment_update" => comment_update,
         "reference_links" => reference_links,
         "requested_state" => Map.get(payload, "target_state")
       }}
    end
  catch
    {:linear_state_lookup_failed, reason} -> {:error, {:linear_state_lookup_failed, reason}}
  end

  defp issue_id_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{id: id} when is_binary(id) and id != "" -> {:ok, id}
      %{"id" => id} when is_binary(id) and id != "" -> {:ok, id}
      %{id: id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :linear_task_context_unavailable}
    end
  end

  defp profile_from_opts(opts) do
    case Keyword.get(opts, :profile) do
      profile when is_binary(profile) and profile != "" -> {:ok, profile}
      _ -> {:error, :workflow_profile_unavailable}
    end
  end

  defp validate_update_policy(payload, profile, opts) do
    policy = Config.workflow_allowed_updates(profile)

    with :ok <- validate_required_allow_true(payload, policy, profile, "description"),
         :ok <- validate_required_allow_true(payload, policy, profile, "result"),
         :ok <- validate_not_explicitly_false(payload, policy, profile, "comment"),
         :ok <- validate_target_state_allowed(payload, policy, profile) do
      validate_implementation_branch_pushed(payload, profile, opts)
    end
  end

  defp validate_required_allow_true(payload, policy, profile, field) do
    if Map.has_key?(payload, field) and Map.get(policy, field) != true do
      {:error, {:update_not_allowed, field, profile}}
    else
      :ok
    end
  end

  defp validate_not_explicitly_false(payload, policy, profile, field) do
    if Map.has_key?(payload, field) and Map.get(policy, field) == false do
      {:error, {:update_not_allowed, field, profile}}
    else
      :ok
    end
  end

  defp validate_target_state_allowed(payload, policy, profile) do
    case Map.get(payload, "target_state") do
      nil ->
        :ok

      target_state ->
        if target_state in Map.get(policy, "target_states", []) do
          :ok
        else
          {:error, {:target_state_not_allowed, target_state, profile, Map.get(policy, "target_states", [])}}
        end
    end
  end

  defp validate_implementation_branch_pushed(%{"target_state" => target_state}, "implementation", opts)
       when is_binary(target_state) do
    if implementation_completion_target?(target_state) and project_repository_configured?() do
      with {:ok, %Issue{branch_name: branch_name}} <- issue_from_opts(opts),
           {:ok, branch} <- BranchName.validate(branch_name),
           {:ok, workspace} <- workspace_from_opts(opts),
           {:ok, true} <- remote_branch_exists?(workspace, branch, opts) do
        :ok
      else
        {:ok, false} -> {:error, {:linear_branch_not_pushed, branch_name_from_opts(opts)}}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp validate_implementation_branch_pushed(_payload, _profile, _opts), do: :ok

  defp implementation_completion_target?(target_state) do
    normalize_state(target_state) != normalize_state("In Progress")
  end

  defp project_repository_configured? do
    case Config.settings!().project.repository_url do
      repository_url when is_binary(repository_url) and repository_url != "" -> true
      _ -> false
    end
  end

  defp issue_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{} = issue -> {:ok, issue}
      _ -> {:error, :linear_task_context_unavailable}
    end
  end

  defp branch_name_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{branch_name: branch_name} -> branch_name
      _ -> nil
    end
  end

  defp workspace_from_opts(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" -> {:ok, workspace}
      _ -> {:error, :workspace_context_unavailable}
    end
  end

  defp remote_branch_exists?(workspace, branch, opts) do
    checker = Keyword.get(opts, :branch_remote_checker)

    if is_function(checker, 2) do
      checker.(workspace, branch)
    else
      Git.remote_branch_exists?(workspace, branch)
    end
  end

  defp normalize_state(state), do: state |> to_string() |> String.trim() |> String.downcase()

  defp maybe_update_issue(issue_id, payload, opts) do
    issue_input =
      %{}
      |> maybe_put_value("description", Map.get(payload, "description"))
      |> maybe_put_state_id(issue_id, Map.get(payload, "target_state"), opts)

    if map_size(issue_input) == 0 do
      {:ok, nil}
    else
      graphql(opts, @issue_update_mutation, %{"id" => issue_id, "input" => issue_input})
    end
  end

  defp maybe_link_references(issue_id, payload, opts) do
    links =
      payload
      |> reference_link_candidates()
      |> dedupe_reference_links()

    Enum.reduce_while(links, {:ok, []}, fn link, {:ok, results} ->
      variables = %{"input" => %{"issueId" => issue_id, "url" => link.url, "title" => link.title}}

      case graphql(opts, @attachment_create_mutation, variables) do
        {:ok, %{"data" => %{"attachmentCreate" => %{"success" => true} = result}}} ->
          {:cont, {:ok, [Map.put(result, "url", link.url) | results]}}

        {:ok, %{"errors" => errors}} ->
          {:halt, {:error, {:linear_attachment_link_failed, errors}}}

        {:ok, result} ->
          {:halt, {:error, {:linear_attachment_link_failed, result}}}

        {:error, reason} ->
          {:halt, {:error, {:linear_attachment_link_failed, reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_create_comment(issue_id, payload, opts) do
    body =
      payload
      |> Map.get("comment")
      |> append_json_section("Result", Map.get(payload, "result"))
      |> append_json_section("References", Map.get(payload, "references"))

    case body do
      body when is_binary(body) ->
        if String.trim(body) == "" do
          {:ok, nil}
        else
          graphql(opts, @comment_create_mutation, %{"issueId" => issue_id, "body" => body})
        end

      _ ->
        {:ok, nil}
    end
  end

  defp maybe_put_value(input, _key, nil), do: input
  defp maybe_put_value(input, key, value), do: Map.put(input, key, value)

  defp maybe_put_state_id(input, _issue_id, nil, _opts), do: input

  defp maybe_put_state_id(input, issue_id, state_name, opts) when is_binary(state_name) do
    case lookup_state_id(issue_id, state_name, opts) do
      {:ok, state_id} -> Map.put(input, "stateId", state_id)
      {:error, reason} -> throw({:linear_state_lookup_failed, reason})
    end
  end

  defp lookup_state_id(issue_id, state_name, opts) do
    with {:ok, response} <- graphql(opts, @issue_team_states_query, %{"id" => issue_id}),
         states when is_list(states) <- get_in(response, ["data", "issue", "team", "states", "nodes"]),
         %{"id" => state_id} <-
           Enum.find(states, fn state -> Map.get(state, "name") == state_name end) do
      {:ok, state_id}
    else
      nil -> {:error, {:linear_state_not_found, state_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:linear_state_not_found, state_name}}
    end
  end

  defp graphql(opts, query, variables) do
    case Keyword.get(opts, :graphql) do
      fun when is_function(fun, 2) -> fun.(query, variables)
      _ -> Client.graphql(query, variables)
    end
  end

  defp reference_link_candidates(payload) do
    []
    |> collect_reference_links(Map.get(payload, "references"))
    |> collect_reference_links(Map.get(payload, "result"))
  end

  defp collect_reference_links(links, value) when is_map(value) do
    Enum.reduce(value, links, fn
      {key, urls}, acc when key in ["urls", :urls] and is_list(urls) ->
        Enum.reduce(urls, acc, &maybe_add_reference_link(&2, "Reference", &1))

      {key, url}, acc ->
        maybe_add_reference_link(acc, reference_title(key), url)
    end)
  end

  defp collect_reference_links(links, _value), do: links

  defp maybe_add_reference_link(links, title, url) when is_binary(url) do
    if http_url?(url) do
      [%{title: title, url: url} | links]
    else
      links
    end
  end

  defp maybe_add_reference_link(links, _title, _url), do: links

  defp dedupe_reference_links(links) do
    links
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.url)
  end

  defp http_url?(url) when is_binary(url) do
    String.starts_with?(url, "https://") or String.starts_with?(url, "http://")
  end

  defp reference_title(key) when key in ["pr_url", :pr_url, "pull_request_url", :pull_request_url], do: "Pull Request"
  defp reference_title(key) when key in ["commit_url", :commit_url], do: "Commit"
  defp reference_title(key) when key in ["branch_url", :branch_url], do: "Branch"
  defp reference_title(_key), do: "Reference"

  defp append_json_section(nil, _title, nil), do: nil

  defp append_json_section(body, _title, nil), do: body

  defp append_json_section(body, title, value) when is_map(value) do
    base = if is_binary(body), do: String.trim(body), else: ""
    section = "#{title}:\n```json\n#{Jason.encode!(value, pretty: true)}\n```"

    if base == "", do: section, else: base <> "\n\n" <> section
  end

  defp normalize_task_read_response(response, include_activity, profile) do
    response
    |> maybe_drop_activity(include_activity)
    |> Map.put("workflow", %{
      "profile" => profile,
      "allowed_updates" => Config.workflow_allowed_updates(profile)
    })
  end

  defp maybe_drop_activity(response, true), do: response

  defp maybe_drop_activity(response, false) when is_map(response) do
    pop_in(response, ["data", "issue", "comments"]) |> elem(1)
  end

  defp success_response(payload), do: dynamic_tool_response(true, encode_payload(payload))
  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(tool, :invalid_arguments) do
    %{"error" => %{"message" => "`#{tool}` expects a JSON object argument."}}
  end

  defp tool_error_payload(@read_tool, :invalid_include_activity) do
    %{"error" => %{"message" => "`linear_task_read.include_activity` must be a boolean."}}
  end

  defp tool_error_payload(@read_tool, :invalid_activity_limit) do
    %{"error" => %{"message" => "`linear_task_read.activity_limit` must be an integer from 1 to 100."}}
  end

  defp tool_error_payload(@read_tool, :invalid_since) do
    %{"error" => %{"message" => "`linear_task_read.since` must be an ISO-8601 string or null."}}
  end

  defp tool_error_payload(@update_tool, :empty_update) do
    %{"error" => %{"message" => "`linear_task_update` requires at least one update field."}}
  end

  defp tool_error_payload(@update_tool, {:invalid_field, field}) do
    %{"error" => %{"message" => "`linear_task_update.#{field}` has an invalid type."}}
  end

  defp tool_error_payload(_tool, :linear_task_context_unavailable) do
    %{
      "error" => %{
        "message" => "Linear task context is unavailable for this Codex session."
      }
    }
  end

  defp tool_error_payload(_tool, :workflow_profile_unavailable) do
    %{
      "error" => %{
        "message" => "Workflow profile is unavailable for this Codex session."
      }
    }
  end

  defp tool_error_payload(_tool, {:update_not_allowed, field, profile}) do
    %{
      "error" => %{
        "message" => "`linear_task_update.#{field}` is not allowed in workflow profile `#{profile}`."
      }
    }
  end

  defp tool_error_payload(_tool, {:target_state_not_allowed, state, profile, allowed}) do
    %{
      "error" => %{
        "message" => "`linear_task_update.target_state` is not allowed in workflow profile `#{profile}`.",
        "requestedState" => state,
        "allowedStates" => allowed
      }
    }
  end

  defp tool_error_payload(_tool, {:linear_state_lookup_failed, reason}) do
    %{
      "error" => %{
        "message" => "Unable to resolve requested Linear workflow state.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(_tool, reason) do
    %{
      "error" => %{
        "message" => "Restricted Linear task tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
