defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.DynamicTool.{IssueCreate, Policy}
  alias SymphonyElixir.Codex.LinearToolAudit
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PersistenceEventWriter

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
  @issue_create_tool "linear_issue_create"
  @pull_request_tool "create_pull_request"

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
    "required" => [
      "title",
      "problem",
      "evidence",
      "why_it_matters",
      "suggested_direction",
      "category"
    ],
    "properties" => %{
      "title" => %{"type" => "string", "description" => "Concise backlog issue title."},
      "problem" => %{"type" => "string", "description" => "Problem or opportunity statement."},
      "evidence" => %{
        "type" => "string",
        "description" => "Concrete evidence from repository code or docs."
      },
      "why_it_matters" => %{
        "type" => "string",
        "description" => "Why this should become backlog work."
      },
      "suggested_direction" => %{
        "type" => "string",
        "description" => "Suggested fix or product direction."
      },
      "category" => %{"type" => "string", "description" => "Finding category."},
      "source_run_id" => %{
        "type" => ["string", "null"],
        "description" => "Source nap/day dreaming run id."
      }
    }
  }

  @pull_request_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["title", "body"],
    "properties" => %{
      "title" => %{"type" => "string", "description" => "Pull request title."},
      "body" => %{
        "type" => "string",
        "description" => "Pull request body conforming to docs/pull-request-body.md."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @read_tool ->
        execute_with_audit(@read_tool, arguments, opts, fn ->
          execute_task_read(arguments, opts)
        end)

      @update_tool ->
        execute_with_audit(@update_tool, arguments, opts, fn ->
          execute_task_update(arguments, opts)
        end)

      @issue_create_tool ->
        execute_with_audit(@issue_create_tool, arguments, opts, fn ->
          execute_issue_create(arguments, opts)
        end)

      @pull_request_tool ->
        execute_with_audit(@pull_request_tool, arguments, opts, fn ->
          execute_pull_request(arguments, opts)
        end)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  defp execute_with_audit(tool, arguments, opts, fun) when is_function(fun, 0) do
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:millisecond)
    response = fun.()
    duration_ms = max(System.monotonic_time(:millisecond) - started_mono, 0)

    LinearToolAudit.record(
      tool,
      arguments,
      response,
      opts
      |> Keyword.put(:audit_started_at, started_at)
      |> Keyword.put(:audit_duration_ms, duration_ms)
    )

    response
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
      },
      %{
        "name" => @pull_request_tool,
        "description" => "Create or find the implementation pull request after commit, validation, and push. Only the implementation profile may call it.",
        "inputSchema" => @pull_request_schema
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
    updater =
      Keyword.get(opts, :task_updater, fn payload -> default_task_updater(payload, opts) end)

    case Policy.normalize_update_arguments(arguments) do
      {:ok, payload} ->
        case updater.(payload) do
          {:ok, result} -> success_response(result)
          {:error, reason} -> failure_response(tool_error_payload(@update_tool, reason))
        end

      {:error, reason} ->
        observe_task_update(
          {:error, reason},
          if(is_map(arguments), do: arguments, else: %{}),
          opts
        )

        failure_response(tool_error_payload(@update_tool, reason))
    end
  end

  defp execute_issue_create(arguments, opts) do
    case IssueCreate.execute(arguments, opts) do
      {:ok, result} ->
        success_response(result)

      {:error, reason} ->
        failure_response(tool_error_payload(@issue_create_tool, reason))
    end
  end

  defp execute_pull_request(arguments, opts) do
    with :ok <- validate_pull_request_profile(opts),
         {:ok, rendered} <- normalize_pull_request_arguments(arguments),
         {:ok, issue} <- issue_from_opts(opts),
         {:ok, pull_request} <- create_pull_request(issue, rendered, opts) do
      success_response(put_pull_request_proof(pull_request, opts))
    else
      {:error, reason} -> failure_response(tool_error_payload(@pull_request_tool, reason))
    end
  end

  defp validate_pull_request_profile(opts) do
    case Keyword.get(opts, :profile) do
      "implementation" -> :ok
      profile when is_binary(profile) -> {:error, {:pull_request_not_allowed, profile}}
      _ -> {:error, :workflow_profile_unavailable}
    end
  end

  defp normalize_pull_request_arguments(arguments) when is_map(arguments) do
    with {:ok, title} <- required_pull_request_text(arguments, "title"),
         {:ok, body} <- required_pull_request_text(arguments, "body") do
      {:ok, %{title: title, body: body}}
    end
  end

  defp normalize_pull_request_arguments(_arguments), do: {:error, :invalid_pull_request_payload}

  defp required_pull_request_text(arguments, field) do
    case Map.get(arguments, field) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, {:invalid_pull_request_field, field}},
          else: {:ok, value}

      _ ->
        {:error, {:invalid_pull_request_field, field}}
    end
  end

  defp create_pull_request(issue, rendered, opts) do
    case Keyword.get(opts, :pull_request_creator) do
      creator when is_function(creator, 3) -> creator.(issue, rendered, opts)
      _ -> {:error, :pull_request_creator_unavailable}
    end
  end

  defp put_pull_request_proof(pull_request, opts) do
    Map.put(pull_request, :completion_proof, pull_request_proof(Map.fetch!(pull_request, :url), opts))
  end

  defp normalize_read_arguments(nil),
    do: {:ok, %{"include_activity" => true, "activity_limit" => 50}}

  defp normalize_read_arguments(arguments) when is_map(arguments) do
    include_activity =
      Map.get(arguments, "include_activity", Map.get(arguments, :include_activity, true))

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
    result =
      with {:ok, issue_id} <- issue_id_from_opts(opts),
           {:ok, profile} <- profile_from_opts(opts),
           :ok <- validate_update_policy(payload, profile),
           :ok <- validate_pull_request_created(payload, profile, opts) do
        if implementation_completion_request?(payload, profile) do
          complete_implementation_handoff(issue_id, payload, opts)
        else
          perform_regular_task_update(issue_id, payload, opts)
        end
      end

    observe_task_update(result, payload, opts)
    result
  catch
    {:linear_state_lookup_failed, reason} -> {:error, {:linear_state_lookup_failed, reason}}
  end

  defp observe_task_update(result, payload, opts) do
    case Keyword.get(opts, :task_update_observer) do
      observer when is_function(observer, 3) -> observer.(result, payload, opts)
      _missing -> :ok
    end
  end

  defp perform_regular_task_update(issue_id, payload, opts) do
    payload = maybe_measure_refinement(payload, opts)
    with {:ok, issue_update} <- maybe_update_issue(issue_id, payload, opts),
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
  end

  defp maybe_measure_refinement(%{"target_state" => target} = payload, opts)
       when target == "Needs Refinement Review" do
    issue = Keyword.get(opts, :issue)
    description = Map.get(payload, "description") || (if match?(%Issue{}, issue), do: issue.description, else: "") || ""
    normalized = String.replace(description, "\r\n", "\n") |> String.replace("\r", "\n")
    chars = String.length(description)
    lines = if normalized == "", do: 0, else: length(String.split(normalized, "\n"))
    limits = refinement_limits()
    labels = if match?(%Issue{}, issue), do: Issue.label_names(issue), else: []
    {char_limit, line_limit, overrides} = effective_limits(limits, labels)
    over = chars > char_limit or lines > line_limit
    comment = Map.get(payload, "comment")
    hint = "Description is #{chars} characters / #{lines} lines (limits #{char_limit} / #{line_limit}); please consider trimming for clarity. This is advisory and will not block refinement."
    payload = if over, do: Map.put(payload, "comment", (if is_binary(comment) and comment != "", do: comment <> "\n\n" <> hint, else: hint)), else: payload
    _ = PersistenceEventWriter.record(%{event_type: "refinement.description_measurement", issue_identifier: issue_identifier(issue), payload: %{characters: chars, lines: lines, character_limit: char_limit, line_limit: line_limit, over_limit: over, label_overrides: overrides}, occurred_at: DateTime.utc_now()}, %{issue_id: issue_id(issue), issue_identifier: issue_identifier(issue)})
    payload
  end
  defp maybe_measure_refinement(payload, _opts), do: payload
  defp issue_id(%Issue{id: id}), do: id
  defp issue_id(_), do: nil
  defp issue_identifier(%Issue{identifier: id}), do: id
  defp issue_identifier(_), do: nil
  defp refinement_limits do
    profile = Config.workflow_profile("refinement")
    Map.get(profile, "description_limits", %{"characters" => 12_000, "lines" => 400, "label_overrides" => %{}})
  end
  defp effective_limits(limits, labels) do
    base = {Map.get(limits, "characters", 12_000), Map.get(limits, "lines", 400)}
    matches = Enum.filter(Map.get(limits, "label_overrides", %{}), fn {label, _} -> String.downcase(to_string(label)) in Enum.map(labels, &String.downcase/1) end) |> Enum.map(fn {_l, v} -> {Map.get(v, "characters", elem(base,0)), Map.get(v, "lines", elem(base,1))} end)
    {max([elem(base,0)|Enum.map(matches, &elem(&1,0))]), max([elem(base,1)|Enum.map(matches, &elem(&1,1))]), Enum.map(matches, fn {c,l} -> %{characters: c, lines: l} end)}
  end

  defp complete_implementation_handoff(issue_id, payload, opts) do
    with {:ok, reference_links} <- maybe_link_references(issue_id, payload, opts),
         {:ok, comment_update} <- maybe_create_comment(issue_id, payload, opts),
         {:ok, issue_update} <- maybe_update_issue(issue_id, payload, opts) do
      {:ok,
       %{
         "issue_update" => issue_update,
         "comment_update" => comment_update,
         "reference_links" => reference_links,
         "requested_state" => Map.get(payload, "target_state")
       }}
    end
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

  defp validate_update_policy(payload, profile) do
    policy = Config.workflow_allowed_updates(profile)

    Policy.validate_update_policy(payload, policy, profile)
  end

  defp implementation_completion_request?(%{"target_state" => target_state}, "implementation") do
    Policy.implementation_completion_target?(target_state)
  end

  defp implementation_completion_request?(_payload, _profile), do: false

  defp validate_pull_request_created(payload, "implementation", opts) do
    case Map.get(payload, "target_state") do
      target_state when is_binary(target_state) ->
        validate_pull_request_created_for_target(payload, target_state, opts)

      _ ->
        :ok
    end
  end

  defp validate_pull_request_created(_payload, _profile, _opts), do: :ok

  defp validate_pull_request_created_for_target(payload, target_state, opts) do
    if Policy.implementation_completion_target?(target_state),
      do: validate_pull_request_proof(payload, opts),
      else: :ok
  end

  defp validate_pull_request_proof(payload, opts) do
    case Policy.pull_request_reference(payload) do
      {:ok, url, proof} ->
        if proof == pull_request_proof(url, opts), do: :ok, else: {:error, :pull_request_not_created}

      _ ->
        {:error, :pull_request_not_created}
    end
  end

  defp pull_request_proof(url, opts) do
    secret = Keyword.fetch!(opts, :pull_request_proof_secret)
    session_id = Keyword.fetch!(opts, :session_id)

    :crypto.mac(:hmac, :sha256, secret, session_id <> <<0>> <> url)
    |> Base.url_encode64(padding: false)
  end

  defp issue_from_opts(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{} = issue -> {:ok, issue}
      _ -> {:error, :linear_task_context_unavailable}
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
      case graphql(opts, @issue_update_mutation, %{"id" => issue_id, "input" => issue_input}) do
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true} = update}}} ->
          {:ok, update}

        {:ok, %{"errors" => errors}} ->
          {:error, {:linear_issue_update_failed, errors}}

        {:ok, response} ->
          {:error, {:linear_issue_update_failed, response}}

        {:error, reason} ->
          {:error, {:linear_issue_update_failed, reason}}
      end
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
          create_comment(issue_id, body, opts)
        end

      _ ->
        {:ok, nil}
    end
  end

  defp create_comment(issue_id, body, opts) do
    case graphql(opts, @comment_create_mutation, %{"issueId" => issue_id, "body" => body}) do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true} = comment}}} ->
        {:ok, comment}

      {:ok, response} ->
        {:error, {:linear_comment_create_failed, response}}

      {:error, reason} ->
        {:error, {:linear_comment_create_failed, reason}}
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
         states when is_list(states) <-
           get_in(response, ["data", "issue", "team", "states", "nodes"]),
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
    %{
      "error" => %{
        "message" => "`linear_task_read.activity_limit` must be an integer from 1 to 100."
      }
    }
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

  defp tool_error_payload(@update_tool, :pull_request_not_created) do
    %{
      "error" => %{
        "message" => "Call `create_pull_request` successfully in this completion session before requesting Ready to Merge."
      }
    }
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
    %{
      "error" => %{
        "message" => "`linear_issue_create` is not allowed in workflow profile `#{profile}`."
      }
    }
  end

  defp tool_error_payload(@issue_create_tool, :invalid_issue_create_payload) do
    %{
      "error" => %{
        "message" => "`linear_issue_create` requires non-empty title, problem, evidence, why_it_matters, suggested_direction, and category."
      }
    }
  end

  defp tool_error_payload(@issue_create_tool, :issue_create_payload_too_large) do
    %{"error" => %{"message" => "`linear_issue_create` payload is too large."}}
  end

  defp tool_error_payload(@pull_request_tool, {:pull_request_not_allowed, profile}) do
    %{
      "error" => %{
        "message" => "`create_pull_request` is not allowed in workflow profile `#{profile}`."
      }
    }
  end

  defp tool_error_payload(@pull_request_tool, {:invalid_pull_request_field, field}) do
    %{
      "error" => %{
        "message" => "`create_pull_request.#{field}` must be a non-empty string."
      }
    }
  end

  defp tool_error_payload(@pull_request_tool, :invalid_pull_request_payload) do
    %{"error" => %{"message" => "`create_pull_request` expects a JSON object argument."}}
  end

  defp tool_error_payload(@pull_request_tool, :pull_request_creator_unavailable) do
    %{
      "error" => %{
        "message" => "Pull request creation is unavailable for this Codex session."
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
