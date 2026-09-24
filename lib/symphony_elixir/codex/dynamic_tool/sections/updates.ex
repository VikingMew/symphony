# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Codex.DynamicTool.Sections.Updates do
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

      defp normalize_read_arguments(_arguments) do
        {:error, :invalid_arguments}
      end

      defp default_task_reader(payload, opts) do
        with {:ok, issue_id} <- issue_id_from_opts(opts),
             {:ok, profile} <- profile_from_opts(opts),
             {:ok, response} <-
               graphql(opts, @task_read_query, %{
                 "id" => issue_id,
                 "commentFirst" => Map.get(payload, "activity_limit", 50)
               }) do
          {:ok,
           normalize_task_read_response(
             response,
             Map.get(payload, "include_activity", true),
             profile,
             Keyword.get(opts, :allowed_updates, %{})
           )}
        end
      end

      defp default_task_updater(payload, opts) do
        result =
          with {:ok, issue_id} <- issue_id_from_opts(opts),
               {:ok, profile} <- profile_from_opts(opts),
               :ok <- validate_refinement_quality(payload, profile, issue_id, opts),
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

      defp validate_refinement_quality(payload, "refinement", issue_id, opts) do
        target_state = Map.get(payload, "target_state")

        if is_binary(target_state) and
             StateName.normalize(target_state) == StateName.normalize("Needs Refinement Review") do
          payload
          |> final_description(opts)
          |> RefinementQualityGate.validate()
          |> report_refinement_quality(issue_id, opts)
        else
          :ok
        end
      end

      defp validate_refinement_quality(_payload, _profile, _issue_id, _opts) do
        :ok
      end

      defp report_refinement_quality(:ok, _issue_id, _opts) do
        :ok
      end

      defp report_refinement_quality({:error, violations}, issue_id, opts) do
        body =
          "Refinement quality gate failed. Fix these items and retry:\n" <>
            Enum.map_join(violations, "\n", fn violation ->
              "- `#{violation.code}`: #{violation.message}"
            end)

        case create_comment(issue_id, body, opts) do
          {:ok, _comment} -> {:error, {:refinement_quality_gate_failed, violations}}
          {:error, reason} -> {:error, reason}
        end
      end

      defp observe_task_update(result, payload, opts) do
        case Keyword.get(opts, :task_update_observer) do
          observer when is_function(observer, 3) -> observer.(result, payload, opts)
          _missing -> :ok
        end
      end

      defp perform_regular_task_update(issue_id, payload, opts) do
        measurement = refinement_measurement(payload, opts)
        payload = maybe_append_measurement_advisory(payload, measurement)

        with {:ok, issue_update} <- maybe_update_issue(issue_id, payload, opts),
             {:ok, reference_links} <- maybe_link_references(issue_id, payload, opts),
             {:ok, comment_update} <- maybe_create_comment(issue_id, payload, opts) do
          record_refinement_measurement(measurement, opts)

          {:ok,
           %{
             "issue_update" => issue_update,
             "comment_update" => comment_update,
             "reference_links" => reference_links,
             "requested_state" => Map.get(payload, "target_state")
           }}
        end
      end

      defp refinement_measurement(%{"target_state" => target} = payload, opts) do
        if StateName.normalize(target) == StateName.normalize("Needs Refinement Review") do
          issue = Keyword.fetch!(opts, :issue)

          RefinementDescriptionMeasurement.measure(
            final_description(payload, opts),
            Issue.label_names(issue),
            Keyword.get_lazy(opts, :refinement_description_limits, fn ->
              Config.workflow_profile("refinement")["description_limits"]
            end)
          )
        end
      end

      defp refinement_measurement(_payload, _opts) do
        nil
      end

      defp final_description(payload, opts) do
        Map.get(payload, "description") || Keyword.fetch!(opts, :issue).description || ""
      end

      defp maybe_append_measurement_advisory(payload, %{over_limit: true} = measurement) do
        advisory = RefinementDescriptionMeasurement.advisory(measurement)

        Map.update(payload, "comment", advisory, fn comment ->
          if is_binary(comment) and comment != "" do
            comment <> "\n\n" <> advisory
          else
            advisory
          end
        end)
      end

      defp maybe_append_measurement_advisory(payload, _measurement) do
        payload
      end

      defp record_refinement_measurement(nil, _opts) do
        :ok
      end

      defp record_refinement_measurement(measurement, opts) do
        issue = Keyword.fetch!(opts, :issue)

        PersistenceEventWriter.record(
          %{
            event_type: "refinement.description_measurement",
            issue_identifier: issue.identifier,
            payload: measurement,
            occurred_at: DateTime.utc_now()
          },
          %{issue_id: issue.id, issue_identifier: issue.identifier}
        )
      end

      defp complete_implementation_handoff(issue_id, payload, opts) do
        with {:ok, review_intent} <- prepare_review_intent(opts),
             {:ok, reference_links} <- maybe_link_references(issue_id, payload, opts),
             {:ok, comment_update} <- maybe_create_comment(issue_id, payload, opts),
             {:ok, issue_update} <- maybe_update_issue(issue_id, payload, opts),
             :ok <- arm_review_intent(review_intent, opts) do
          {:ok,
           %{
             "issue_update" => issue_update,
             "comment_update" => comment_update,
             "reference_links" => reference_links,
             "requested_state" => Map.get(payload, "target_state")
           }}
        end
      end

      defp prepare_review_intent(opts) do
        case Keyword.get(opts, :review_intent_preparer) do
          preparer when is_function(preparer, 1) ->
            getter = Keyword.fetch!(opts, :pull_request_result)
            preparer.(getter.())

          _missing ->
            {:ok, nil}
        end
      end

      defp arm_review_intent(nil, _opts) do
        :ok
      end

      defp arm_review_intent(intent, opts) do
        case Keyword.get(opts, :review_intent_armer) do
          armer when is_function(armer, 1) -> armer.(intent)
          _missing -> {:error, :review_intent_armer_unavailable}
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

      defp implementation_completion_request?(%{"target_state" => target_state}, "implementation") do
        Policy.implementation_completion_target?(target_state)
      end

      defp implementation_completion_request?(_payload, _profile) do
        false
      end

      defp validate_pull_request_created(payload, "implementation", opts) do
        case Map.get(payload, "target_state") do
          target_state when is_binary(target_state) ->
            validate_pull_request_created_for_target(payload, target_state, opts)

          _ ->
            :ok
        end
      end

      defp validate_pull_request_created(_payload, _profile, _opts) do
        :ok
      end

      defp validate_pull_request_created_for_target(payload, target_state, opts) do
        if Policy.implementation_completion_target?(target_state) do
          validate_pull_request_proof(payload, opts)
        else
          :ok
        end
      end

      defp validate_pull_request_proof(payload, opts) do
        case Policy.pull_request_reference(payload) do
          {:ok, url, proof} ->
            if proof == pull_request_proof(url, opts) do
              :ok
            else
              {:error, :pull_request_not_created}
            end

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

      defp maybe_put_value(input, _key, nil) do
        input
      end

      defp maybe_put_value(input, key, value) do
        Map.put(input, key, value)
      end

      defp maybe_put_state_id(input, _issue_id, nil, _opts) do
        input
      end

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

      defp append_json_section(nil, _title, nil) do
        nil
      end

      defp append_json_section(body, _title, nil) do
        body
      end

      defp append_json_section(body, title, value) when is_map(value) do
        base =
          if is_binary(body) do
            String.trim(body)
          else
            ""
          end

        section = "#{title}:
    ```json
    #{Jason.encode!(value, pretty: true)}
    ```"

        if base == "" do
          section
        else
          base <> "\n\n" <> section
        end
      end

      defp normalize_task_read_response(response, include_activity, profile, allowed_updates) do
        response
        |> maybe_drop_activity(include_activity)
        |> Map.put("workflow", %{
          "profile" => profile,
          "allowed_updates" => allowed_updates
        })
      end

      defp maybe_drop_activity(response, true) do
        response
      end

      defp maybe_drop_activity(response, false) when is_map(response) do
        pop_in(response, ["data", "issue", "comments"]) |> elem(1)
      end

      defp success_response(payload) do
        dynamic_tool_response(true, encode_payload(payload))
      end

      defp failure_response(payload) do
        dynamic_tool_response(false, encode_payload(payload))
      end

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

      defp encode_payload(payload) do
        inspect(payload)
      end

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

      defp tool_error_payload(@handoff_tool, {:handoff_not_allowed, profile}) do
        %{
          "error" => %{
            "message" => "`handoff` is only available to implementation (got #{inspect(profile)})."
          }
        }
      end

      defp tool_error_payload(@handoff_tool, :handoff_submitter_unavailable) do
        %{"error" => %{"message" => "handoff submission is unavailable in this session."}}
      end

      defp tool_error_payload(@handoff_tool, {:invalid_handoff_field, field}) do
        %{"error" => %{"message" => "`handoff.#{field}` is required and must be non-empty."}}
      end

      defp tool_error_payload(@handoff_tool, :pull_request_not_created) do
        %{
          "error" => %{"message" => "Call `create_pull_request` successfully before calling `handoff`."}
        }
      end

      defp tool_error_payload(_tool, {:refinement_quality_gate_failed, items}) do
        %{
          "error" => %{
            "code" => "refinement_quality_gate_failed",
            "message" => "Refinement quality gate failed.",
            "missing" => items
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
  end
end
