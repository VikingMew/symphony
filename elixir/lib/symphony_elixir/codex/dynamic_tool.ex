defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{BranchName, Config, Git, Linear.Client, Linear.Issue}
  alias SymphonyElixir.Codex.DynamicTool.Policy

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

  @issue_create_context_query """
  query SymphonyLinearIssueCreateContext($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        name
        teams(first: 5) {
          nodes {
            id
            name
            states(first: 100) {
              nodes {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @issue_create_mutation """
  mutation SymphonyLinearIssueCreate($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  @read_tool "linear_task_read"
  @update_tool "linear_task_update"
  @issue_create_tool "linear_issue_create"

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

  @issue_create_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["title", "problem", "evidence", "why_it_matters", "suggested_direction", "category"],
    "properties" => %{
      "title" => %{"type" => "string", "description" => "Concise backlog issue title."},
      "problem" => %{"type" => "string", "description" => "Problem or opportunity statement."},
      "evidence" => %{"type" => "string", "description" => "Concrete evidence from repository code or docs."},
      "why_it_matters" => %{"type" => "string", "description" => "Why this should become backlog work."},
      "suggested_direction" => %{"type" => "string", "description" => "Suggested fix or product direction."},
      "category" => %{"type" => "string", "description" => "Finding category."},
      "source_run_id" => %{"type" => ["string", "null"], "description" => "Source nap/day dreaming run id."}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @read_tool ->
        execute_task_read(arguments, opts)

      @update_tool ->
        execute_task_update(arguments, opts)

      @issue_create_tool ->
        execute_issue_create(arguments, opts)

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
      },
      %{
        "name" => @issue_create_tool,
        "description" => "Create a new backlog Linear issue through Symphony's restricted issue-creation policy. Only nap and day_dreaming profiles may use it.",
        "inputSchema" => @issue_create_schema
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

    with {:ok, payload} <- Policy.normalize_update_arguments(arguments),
         {:ok, result} <- updater.(payload) do
      success_response(result)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(@update_tool, reason))
    end
  end

  defp execute_issue_create(arguments, opts) do
    creator = Keyword.get(opts, :issue_creator, fn payload -> default_issue_creator(payload, opts) end)

    with {:ok, profile} <- profile_from_opts(opts),
         :ok <- validate_issue_create_profile(profile),
         {:ok, payload} <- normalize_issue_create_arguments(arguments),
         {:ok, result} <- creator.(payload) do
      success_response(result)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(@issue_create_tool, reason))
    end
  end

  defp validate_issue_create_profile(profile) when profile in ["nap", "day_dreaming"], do: :ok
  defp validate_issue_create_profile(profile), do: {:error, {:issue_create_not_allowed, profile}}

  defp blank_string?(value), do: !is_binary(value) or String.trim(value) == ""

  defp normalize_issue_create_arguments(arguments) when is_map(arguments) do
    payload =
      arguments
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
      |> Map.take(["title", "problem", "evidence", "why_it_matters", "suggested_direction", "category", "source_run_id"])

    required = ["title", "problem", "evidence", "why_it_matters", "suggested_direction", "category"]

    cond do
      Enum.any?(required, &blank_string?(Map.get(payload, &1))) ->
        {:error, :invalid_issue_create_payload}

      payload |> Map.values() |> Enum.any?(&(is_binary(&1) and String.length(&1) > 8_000)) ->
        {:error, :issue_create_payload_too_large}

      true ->
        {:ok, payload}
    end
  end

  defp normalize_issue_create_arguments(_arguments), do: {:error, :invalid_issue_create_payload}

  defp default_issue_creator(payload, opts) do
    settings = Config.settings!()
    project_slug = settings.tracker.project_slug
    backlog_state = get_in(settings.workflow, ["backlog_state"]) || "Backlog"

    with project_slug when is_binary(project_slug) and project_slug != "" <- project_slug,
         {:ok, context} <- graphql(opts, @issue_create_context_query, %{"projectSlug" => project_slug}),
         {:ok, project, team, state} <- issue_create_context(context, backlog_state),
         input <- issue_create_input(payload, project, team, state),
         {:ok, response} <- graphql(opts, @issue_create_mutation, %{"input" => input}) do
      normalize_issue_create_response(response)
    else
      nil -> {:error, :missing_linear_project_slug}
      "" -> {:error, :missing_linear_project_slug}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :linear_issue_create_context_unavailable}
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

  defp issue_create_context(response, backlog_state) do
    with [project | _] <- get_in(response, ["data", "projects", "nodes"]),
         teams when is_list(teams) <- get_in(project, ["teams", "nodes"]),
         {team, state} <- find_team_state(teams, backlog_state) do
      {:ok, project, team, state}
    else
      nil -> {:error, {:linear_state_not_found, backlog_state}}
      [] -> {:error, :linear_project_not_found}
      _ -> {:error, :linear_issue_create_context_unavailable}
    end
  end

  defp find_team_state(teams, backlog_state) do
    Enum.find_value(teams, fn team ->
      state =
        team
        |> get_in(["states", "nodes"])
        |> case do
          states when is_list(states) -> Enum.find(states, &(Map.get(&1, "name") == backlog_state))
          _ -> nil
        end

      if state, do: {team, state}
    end)
  end

  defp issue_create_input(payload, project, team, state) do
    %{
      "teamId" => Map.fetch!(team, "id"),
      "projectId" => Map.fetch!(project, "id"),
      "stateId" => Map.fetch!(state, "id"),
      "title" => Map.fetch!(payload, "title"),
      "description" => issue_create_description(payload)
    }
  end

  defp issue_create_description(payload) do
    [
      {"Problem", Map.get(payload, "problem")},
      {"Evidence", Map.get(payload, "evidence")},
      {"Why it matters", Map.get(payload, "why_it_matters")},
      {"Suggested direction", Map.get(payload, "suggested_direction")},
      {"Category", Map.get(payload, "category")},
      {"Source run", Map.get(payload, "source_run_id")}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) or (is_binary(value) and String.trim(value) == "") end)
    |> Enum.map_join("\n\n", fn {label, value} -> "### #{label}\n#{value}" end)
  end

  defp normalize_issue_create_response(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}) do
    {:ok,
     %{
       "id" => Map.get(issue, "id"),
       "identifier" => Map.get(issue, "identifier"),
       "title" => Map.get(issue, "title"),
       "url" => Map.get(issue, "url"),
       "state" => get_in(issue, ["state", "name"])
     }}
  end

  defp normalize_issue_create_response(%{"errors" => errors}), do: {:error, {:linear_graphql_errors, errors}}
  defp normalize_issue_create_response(payload), do: {:error, {:unexpected_issue_create_payload, payload}}

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

    with :ok <- Policy.validate_update_policy(payload, policy, profile) do
      validate_implementation_branch_pushed(payload, profile, opts)
    end
  end

  defp validate_implementation_branch_pushed(%{"target_state" => target_state}, "implementation", opts)
       when is_binary(target_state) do
    if Policy.implementation_completion_target?(target_state) and project_repository_configured?() do
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
      |> Policy.reference_link_candidates()

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

  defp tool_error_payload(@issue_create_tool, {:issue_create_not_allowed, profile}) do
    %{"error" => %{"message" => "`linear_issue_create` is not allowed in workflow profile `#{profile}`."}}
  end

  defp tool_error_payload(@issue_create_tool, :invalid_issue_create_payload) do
    %{"error" => %{"message" => "`linear_issue_create` requires non-empty title, problem, evidence, why_it_matters, suggested_direction, and category."}}
  end

  defp tool_error_payload(@issue_create_tool, :issue_create_payload_too_large) do
    %{"error" => %{"message" => "`linear_issue_create` payload is too large."}}
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
