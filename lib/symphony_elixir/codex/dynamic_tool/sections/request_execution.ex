# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.DynamicTool.Sections.RequestExecution do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      alias SymphonyElixir.Codex.DynamicTool.{IssueCreate, Policy}
      alias SymphonyElixir.Codex.LinearToolAudit
      alias SymphonyElixir.Codex.RefinementDescriptionMeasurement
      alias SymphonyElixir.Codex.RefinementQualityGate
      alias SymphonyElixir.Config
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.PersistenceEventWriter
      alias SymphonyElixir.PRReview
      alias SymphonyElixir.StateName

      @task_read_query "query SymphonyLinearTaskRead($id: String!, $commentFirst: Int!) {\n  issue(id: $id) {\n    id\n    identifier\n    title\n    description\n    url\n    branchName\n    priority\n    state {\n      name\n    }\n    labels {\n      nodes {\n        name\n      }\n    }\n    comments(first: $commentFirst) {\n      nodes {\n        id\n        body\n        createdAt\n        updatedAt\n        user {\n          name\n        }\n      }\n    }\n  }\n}\n"

      @issue_team_states_query "query SymphonyLinearIssueTeamStates($id: String!) {\n  issue(id: $id) {\n    team {\n      states(first: 100) {\n        nodes {\n          id\n          name\n        }\n      }\n    }\n  }\n}\n"

      @issue_update_mutation "mutation SymphonyLinearTaskIssueUpdate($id: String!, $input: IssueUpdateInput!) {\n  issueUpdate(id: $id, input: $input) {\n    success\n    issue {\n      id\n      identifier\n      state {\n        name\n      }\n      updatedAt\n    }\n  }\n}\n"

      @comment_create_mutation "mutation SymphonyLinearTaskCommentCreate($issueId: String!, $body: String!) {\n  commentCreate(input: {issueId: $issueId, body: $body}) {\n    success\n    comment {\n      id\n      createdAt\n    }\n  }\n}\n"

      @attachment_create_mutation "mutation SymphonyLinearTaskAttachmentCreate($input: AttachmentCreateInput!) {\n  attachmentCreate(input: $input) {\n    success\n    attachment {\n      id\n      title\n    }\n  }\n}\n"

      @read_tool "linear_task_read"
      @update_tool "linear_task_update"
      @issue_create_tool "linear_issue_create"
      @pull_request_tool "create_pull_request"
      @handoff_tool "handoff"
      @review_context_tool "review_context_read"
      @review_submit_tool "submit_review"

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

      @handoff_schema %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["comment", "result", "references"],
        "properties" => %{
          "comment" => %{"type" => "string"},
          "result" => %{"type" => "object", "additionalProperties" => true},
          "references" => %{
            "type" => "object",
            "additionalProperties" => true,
            "required" => ["branch", "commit", "pr_url", "pr_proof"]
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

          @handoff_tool ->
            execute_with_audit(@handoff_tool, arguments, opts, fn ->
              execute_handoff(arguments, opts)
            end)

          @review_context_tool ->
            execute_review_context(arguments, opts)

          @review_submit_tool ->
            execute_review_submit(arguments, opts)

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
          },
          handoff_tool_spec()
        ]
      end

      @spec tool_specs(String.t() | nil) :: [map()]
      def tool_specs("review") do
        [
          %{
            "name" => @review_context_tool,
            "description" => "Read the immutable issue and pull-request review context.",
            "inputSchema" => %{"type" => "object", "additionalProperties" => false}
          },
          %{
            "name" => @review_submit_tool,
            "description" => "Submit the single structured review conclusion.",
            "inputSchema" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["outcome", "head_sha", "summary", "findings"],
              "properties" => %{
                "outcome" => %{"type" => "string", "enum" => ["approve", "findings"]},
                "head_sha" => %{"type" => "string"},
                "summary" => %{"type" => "string"},
                "findings" => %{"type" => "array", "items" => %{"type" => "string"}}
              }
            }
          }
        ]
      end

      def tool_specs("implementation") do
        tool_specs()
      end

      def tool_specs(_profile) do
        tool_specs()
      end

      defp execute_review_context(arguments, opts) do
        with "review" <- Keyword.get(opts, :profile),
             true <- arguments in [nil, %{}],
             context when is_map(context) <- Keyword.get(opts, :review_context) do
          success_response(context)
        else
          _ -> failure_response(%{"error" => %{"message" => "Review context is unavailable."}})
        end
      end

      defp execute_review_submit(arguments, opts) do
        with "review" <- Keyword.get(opts, :profile),
             {:ok, result} <- normalize_review_result(arguments),
             true <- result.head_sha == Keyword.fetch!(opts, :review_head_oid),
             submitter when is_function(submitter, 1) <- Keyword.get(opts, :review_submitter),
             :ok <- submitter.(result) do
          success_response(%{"accepted" => true})
        else
          false ->
            failure_response(%{
              "error" => %{"message" => "Reviewed head SHA does not match the immutable job head."}
            })

          _ ->
            failure_response(%{"error" => %{"message" => "Invalid review conclusion."}})
        end
      end

      defp normalize_review_result(arguments) when is_map(arguments) do
        outcome = Map.get(arguments, "outcome")
        PRReview.normalize(Map.put(arguments, "outcome", review_outcome(outcome)))
      end

      defp normalize_review_result(_arguments) do
        {:error, :invalid_review_result}
      end

      defp review_outcome("approve") do
        :approve
      end

      defp review_outcome("findings") do
        :findings
      end

      defp review_outcome(other) do
        other
      end

      defp handoff_tool_spec do
        %{
          "name" => @handoff_tool,
          "description" => "Submit the completed implementation payload after create_pull_request. Acceptance does not update Linear; the worker writes it back only after required gates pass.",
          "inputSchema" => @handoff_schema
        }
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
              if is_map(arguments) do
                arguments
              else
                %{}
              end,
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
          result = put_pull_request_proof(pull_request, opts)
          observe_pull_request(result, opts)
          success_response(result)
        else
          {:error, reason} -> failure_response(tool_error_payload(@pull_request_tool, reason))
        end
      end

      defp execute_handoff(arguments, opts) do
        with :ok <- validate_handoff_profile(opts),
             {:ok, payload} <- normalize_handoff_arguments(arguments),
             :ok <- validate_submitted_pull_request(payload, opts),
             submitter when is_function(submitter, 1) <- Keyword.get(opts, :handoff_submitter),
             :ok <- submitter.(payload) do
          success_response(%{"accepted" => true, "linear_updated" => false})
        else
          nil -> failure_response(tool_error_payload(@handoff_tool, :handoff_submitter_unavailable))
          {:error, reason} -> failure_response(tool_error_payload(@handoff_tool, reason))
        end
      end

      defp validate_handoff_profile(opts) do
        if Keyword.get(opts, :profile) == "implementation" do
          :ok
        else
          {:error, {:handoff_not_allowed, Keyword.get(opts, :profile)}}
        end
      end

      defp normalize_handoff_arguments(arguments) when is_map(arguments) do
        with {:ok, comment} <- required_handoff_text(arguments, "comment"),
             {:ok, result} <- required_handoff_map(arguments, "result"),
             {:ok, references} <- required_handoff_map(arguments, "references"),
             {:ok, branch} <- required_handoff_text(references, "branch", "references.branch"),
             {:ok, commit} <- required_handoff_text(references, "commit", "references.commit"),
             {:ok, _url} <- required_handoff_text(references, "pr_url", "references.pr_url"),
             {:ok, _proof} <- required_handoff_text(references, "pr_proof", "references.pr_proof") do
          {:ok,
           %{
             "comment" => comment,
             "result" => result,
             "references" => Map.merge(references, %{"branch" => branch, "commit" => commit})
           }}
        end
      end

      defp normalize_handoff_arguments(_) do
        {:error, {:invalid_handoff_field, "handoff"}}
      end

      defp required_handoff_text(map, key, path \\ nil) do
        case Map.get(map, key) do
          value when is_binary(value) ->
            if String.trim(value) == "" do
              {:error, {:invalid_handoff_field, path || key}}
            else
              {:ok, String.trim(value)}
            end

          _ ->
            {:error, {:invalid_handoff_field, path || key}}
        end
      end

      defp required_handoff_map(map, key) do
        case Map.get(map, key) do
          value when is_map(value) and map_size(value) > 0 -> {:ok, value}
          _ -> {:error, {:invalid_handoff_field, key}}
        end
      end

      defp validate_submitted_pull_request(payload, opts) do
        with getter when is_function(getter, 0) <- Keyword.get(opts, :pull_request_result),
             %{url: url, completion_proof: proof} <- getter.(),
             {:ok, ^url, ^proof} <- Policy.pull_request_reference(payload) do
          :ok
        else
          _ -> {:error, :pull_request_not_created}
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

      defp normalize_pull_request_arguments(_arguments) do
        {:error, :invalid_pull_request_payload}
      end

      defp required_pull_request_text(arguments, field) do
        case Map.get(arguments, field) do
          value when is_binary(value) ->
            if String.trim(value) == "" do
              {:error, {:invalid_pull_request_field, field}}
            else
              {:ok, value}
            end

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
        Map.put(
          pull_request,
          :completion_proof,
          pull_request_proof(Map.fetch!(pull_request, :url), opts)
        )
      end

      defp observe_pull_request(result, opts) do
        case Keyword.get(opts, :pull_request_observer) do
          observer when is_function(observer, 1) -> observer.(result)
          _ -> :ok
        end
      end

      defp normalize_read_arguments(nil) do
        {:ok, %{"include_activity" => true, "activity_limit" => 50}}
      end

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
    end
  end
end
