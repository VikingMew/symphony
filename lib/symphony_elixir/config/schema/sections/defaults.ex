# Locality split index: docs/code-locality.md#temporary-clause-splits
defmodule SymphonyElixir.Config.Schema.Sections.Defaults do
  @moduledoc false

  @spec __using__(term()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import Ecto.Changeset

      alias SymphonyElixir.Codex.ModelCatalog
      alias SymphonyElixir.Config.{CodexCommand, ProjectCommands, RuntimeResolver, WorkflowContract}

      alias SymphonyElixir.Config.Schema.{
        Agent,
        Analytics,
        Codex,
        Hooks,
        Observability,
        Polling,
        Project,
        Server,
        StringOrMap,
        Tracker,
        Worker,
        Workspace
      }

      def default_workflow_policy do
        %{
          "states" => %{
            "Todo" => %{"profile" => "refinement"},
            "Refining" => %{"profile" => "refinement"},
            "Ready" => %{"profile" => "implementation"},
            "In Progress" => %{"profile" => "implementation"}
          },
          "human_review_states" => ["Needs Refinement Review", "Ready to Merge", "Blocked"],
          "allowed_transitions" => [
            %{"from" => "Todo", "to" => "Refining", "actor" => "codex", "profile" => "refinement"},
            %{
              "from" => "Refining",
              "to" => "Needs Refinement Review",
              "actor" => "codex",
              "profile" => "refinement"
            },
            %{"from" => "Needs Refinement Review", "to" => "Ready", "actor" => "human"},
            %{"from" => "Needs Refinement Review", "to" => "Refining", "actor" => "human"},
            %{
              "from" => "Ready",
              "to" => "In Progress",
              "actor" => "codex",
              "profile" => "implementation"
            },
            %{
              "from" => "In Progress",
              "to" => "Ready to Merge",
              "actor" => "codex",
              "profile" => "implementation"
            },
            %{"from" => "Ready to Merge", "to" => "In Progress", "actor" => "human"},
            %{"from" => "Todo", "to" => "Blocked", "actor" => "symphony"},
            %{"from" => "Refining", "to" => "Blocked", "actor" => "symphony"},
            %{"from" => "Ready", "to" => "Blocked", "actor" => "symphony"},
            %{"from" => "In Progress", "to" => "Blocked", "actor" => "symphony"},
            %{"from" => "Ready to Merge", "to" => "Blocked", "actor" => "symphony"},
            %{"from" => "Blocked", "to" => "Ready", "actor" => "human"},
            %{"from" => "Blocked", "to" => "In Progress", "actor" => "human"},
            %{"from" => "Blocked", "to" => "Needs Refinement Review", "actor" => "human"},
            %{"from" => "Blocked", "to" => "Canceled", "actor" => "human"}
          ],
          "tool_policy" => %{
            "linear" => %{
              "exposed_tools" => ["linear_task_read", "linear_task_update"],
              "raw_graphql" => false
            },
            "github" => %{
              "exposed_tools" => ["create_pull_request"],
              "profiles" => ["implementation"]
            }
          }
        }
      end

      @doc false
      @spec default_profiles() :: map()
      def default_profiles do
        %{
          "refinement" => %{
            "name" => "Refinement",
            "executor" => %{"type" => "codex_agent"},
            "prompt" => %{
              "mode" => "extend",
              "template" =>
                "Workflow profile: {{ workflow.profile_name }}\n\nRead the task and recent Linear comments. Refine the task description and acceptance criteria only when the feedback and repository context justify it. Every candidate description must include a non-empty `Owning design docs` ATX section with `Change classification: behavior/architecture|non-behavior` and `Design sync: required|not required`. Behavior/architecture work must list each `docs/*-design.md` owner in that section and reference every owner in Scope and Acceptance criteria. If no owner exists, use `No owner: true` and add a non-empty `Owner registration plan:` item to both sections. Non-behavior work with sync not required must include a non-empty `Reason:`. Do not add safety, redundancy, misuse-prevention, versioning, compatibility, fallback, or defensive-programming designs unless the issue literally requires them. Judge scope by the issue's literal text: if it does not require such a design, do not add it. Keep the design minimal and align with AGENTS.md's no-defensive-programming and pre-release stance. When the task is ready for human confirmation, add a concise comment and request one of the allowed target states."
            },
            "allowed_updates" => %{
              "description" => true,
              "comment" => true,
              "result" => false,
              "target_states" => ["Needs Refinement Review"]
            },
            "description_limits" => %{"characters" => 12_000, "lines" => 400, "label_overrides" => %{}}
          },
          "implementation" => %{
            "name" => "Implementation",
            "executor" => %{"type" => "codex_agent"},
            "prompt" => %{
              "mode" => "extend",
              "template" =>
                "Workflow profile: {{ workflow.profile_name }}\n\nRead the task and recent Linear comments before changing code. Review the owning-design declaration against the actual diff before delivery. Changes to behavior under `lib/` or to runtime configuration semantics require the owning L3 design and its documentation-alignment row in the same change. If the diff disagrees with the ticket classification, correct the Linear description or work record and documentation scope before delivery. A missing owner must be disclosed in the PR body and registered as a new L3 owner or merged into an existing owner in the same PR; it is not an exemption. Do not add safety, redundancy, misuse-prevention, versioning, compatibility, fallback, or defensive-programming designs unless the issue literally requires them. Judge scope by the issue's literal text: if it does not require such a design, do not add it. Keep the implementation minimal and align with AGENTS.md's no-defensive-programming and pre-release stance. Implement, validate, commit, and push the exact Linear branchName. Call create_pull_request with a title/body conforming to docs/pull-request-body.md, then call the handoff dynamic tool with the final comment, result, and references including its URL and completion proof. Handoff acceptance does not update Linear immediately; the worker runs required gates and only then writes Ready to Merge through the restricted backend. Symphony owns the tool backend and credentials. After human change requests return the issue to In Progress, update the same branch and PR, validate, and submit handoff again."
            },
            "allowed_updates" => %{
              "description" => false,
              "comment" => true,
              "result" => true,
              "target_states" => ["In Progress", "Ready to Merge"]
            }
          },
          "review" => %{
            "name" => "Pull request review",
            "executor" => %{"type" => "codex_agent"},
            "prompt" => %{
              "mode" => "replace",
              "template" => "Review only the supplied immutable issue and pull-request context. Submit one structured approve/findings conclusion. Do not modify code, git, GitHub, or Linear."
            },
            "allowed_updates" => %{
              "description" => false,
              "comment" => false,
              "result" => false,
              "target_states" => []
            }
          },
          "nap" => %{
            "name" => "Nap audit",
            "executor" => %{"type" => "codex_agent"},
            "prompt" => %{
              "mode" => "replace",
              "template" =>
                "Workflow profile: nap\n\nRead the repository and project documentation. Lower code complexity by finding three categories of problems:\n\n1. Redundancy: repeated logic, near-duplicate functions, and copied blocks; redundant error handling, including repeated rescue/retry/wrap, defensive re-validation of already-validated data, and catch-all rescues that hide real failures; and redundant gating, including redundant feature flags, conditions that can never be false, and duplicated permission or capability checks across layers.\n2. Unreasonable mutual dependencies: incidental coupling, cyclic module dependencies, god modules, hidden shared state (ETS, globals, or the process dictionary), string-discriminated behavior, dual representation of one fact, and indirection layers with only one implementation.\n3. Dead weight: speculative abstractions, unread config keys, compatibility shims, and commented-out code.\n\nBefore reviewing, run a mechanical scan pre-step:\n- `mix xref graph` for unconsumed exports and functions.\n- `mix deps.tree` plus dependency-unused checks.\n- Credo duplicate-code and cyclomatic-complexity checks.\n- `mix dialyzer` for dead code such as `unused_fun`; OTP28 `unused_fun` has known false positives, so manually re-check the output.\nTool output is evidence, not a verdict; pair it with manual review.\n\nAudit these additional dimensions:\n- Stale exemption lists: `.dialyzer_ignore.exs`, Credo exemptions, `@tag :skip` tests, and disabled lint rules. Does the covered code still exist? Can an entry be tightened or the entire baseline dropped?\n- Unconsumed public APIs and events: public exports, `GenServer.call` or `GenServer.cast`, and event topics with no real consumer, backed by `mix xref graph`.\n- Hand-maintained documentation whose source of truth already exists in code, including config keys derivable from `schema.ex`, module lists, and indexes. Archive stale documentation instead of physically deleting it.\n- Gate-then-zero fix directions: introduce a gate, zero the debt, then drop the exemption baseline instead of doing one-off cleanup.\n\nFor every candidate, explicitly evaluate it against each of these Linus & Carmack criteria. State which criterion it violates and why:\n- Linus: remove complexity, keep good taste — making the system simpler is better than making it more elaborate; reject architecture-astronaut abstractions; code must earn its place.\n- Linus: talk is cheap, show me the code — prefer concrete, working, minimal changes over design essays.\n- Carmack: minimize the number of things that can go wrong — every flag, abstraction, and catch-all is another possible failure; do not represent one fact twice.\n- Carmack: hard to make simple is still worth it — hard-to-understand code is hard to make correct; simplify it instead of documenting around it.\n- Explicit errors over silent tolerance — failures must be visible and typed; never swallow a crash merely to keep a pipeline alive without a record.\n\nApply anti-false-positive discipline. Re-check every mechanical result manually, especially OTP28 dialyzer `unused_fun`. Distinguish pure deletion from reorganization or migration: if a capability is still used but misplaced, propose reorganization. For uncertain candidates, write Keep as-is instead of noise.\n\nThis profile proposes deletion or optimization directions; it does not delete. Do not modify code. Do not modify documentation. Do not create commits or pull requests. For every distinct problem that violates at least one criterion, create one Backlog Linear issue through the restricted issue creation tool. Each issue must include a concise title, evidence (file/line or code excerpt), the discovery path (mechanical scan output or manual review), the violated criterion and why, complexity impact, a fix direction that reduces complexity, and a verification path proving behavior remains unchanged after removal (`make all`, targeted tests, or `mix dialyzer`)."
            },
            "allowed_updates" => %{
              "description" => false,
              "comment" => false,
              "result" => false,
              "target_states" => []
            }
          },
          "day_dreaming" => %{
            "name" => "Day dreaming",
            "executor" => %{"type" => "codex_agent"},
            "prompt" => %{
              "mode" => "replace",
              "template" =>
                "Workflow profile: day_dreaming\n\nRead the existing code, README, architecture docs, long-term direction docs, and other relevant canonical documentation. Compare implementation reality with product direction and identify useful features or optimization opportunities that should be developed next. Every opportunity must be supported by evidence from code or documentation, align with the long-term direction, and not duplicate an existing Backlog issue.\n\nDo not modify code. Do not modify documentation. Do not create commits or pull requests. For every distinct product or engineering opportunity, create one Backlog Linear issue through the restricted issue creation tool with a concise title, evidence from code/docs, why it matters, suggested direction, and rough impact."
            },
            "allowed_updates" => %{
              "description" => false,
              "comment" => false,
              "result" => false,
              "target_states" => []
            }
          }
        }
      end

      defp normalize_profiles(profiles) when is_map(profiles) do
        configured_profiles = normalize_keys(profiles)

        default_profiles()
        |> Map.merge(configured_profiles, fn _profile, default_profile, configured_profile ->
          Map.merge(default_profile, configured_profile)
        end)
      end

      defp normalize_profiles(_profiles) do
        default_profiles()
      end

      defp validate_workflow_contract(changeset) do
        workflow = get_field(changeset, :workflow) || %{}
        profiles = get_field(changeset, :profiles) || %{}
        tracker = get_field(changeset, :tracker)

        workflow_errors =
          WorkflowContract.workflow_errors(workflow, profiles, tracker)

        profile_errors =
          WorkflowContract.profile_errors(profiles) ++ description_limit_errors(profiles)

        Enum.reduce(workflow_errors, changeset, &add_error(&2, :workflow, &1))
        |> then(fn changeset ->
          Enum.reduce(profile_errors, changeset, &add_error(&2, :profiles, &1))
        end)
      end

      defp description_limit_errors(profiles) do
        case get_in(profiles, ["refinement", "description_limits"]) do
          nil ->
            []

          limits when is_map(limits) ->
            limit_map_errors(limits, "profiles.refinement.description_limits")

          _ ->
            ["profiles.refinement.description_limits must be a map"]
        end
      end

      defp limit_map_errors(limits, path) do
        scalar_errors =
          Enum.flat_map(["characters", "lines"], fn key ->
            case Map.get(limits, key) do
              nil -> []
              value when is_integer(value) and value > 0 -> []
              _ -> ["#{path}.#{key} must be a positive integer"]
            end
          end)

        override_errors =
          case Map.get(limits, "label_overrides", %{}) do
            overrides when is_map(overrides) ->
              Enum.flat_map(overrides, fn
                {label, override} when is_map(override) ->
                  limit_map_errors(
                    Map.delete(override, "label_overrides"),
                    "#{path}.label_overrides.#{label}"
                  )

                {label, _override} ->
                  ["#{path}.label_overrides.#{label} must be a map"]
              end)

            _ ->
              ["#{path}.label_overrides must be a map"]
          end

        scalar_errors ++ override_errors
      end

      defp normalize_keys(value) when is_map(value) do
        Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
          Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
        end)
      end

      defp normalize_keys(value) when is_list(value) do
        Enum.map(value, &normalize_keys/1)
      end

      defp normalize_keys(value) do
        value
      end

      defp normalize_optional_map(nil) do
        nil
      end

      defp normalize_optional_map(value) when is_map(value) do
        normalize_keys(value)
      end

      defp normalize_key(value) when is_atom(value) do
        Atom.to_string(value)
      end

      defp normalize_key(value) do
        to_string(value)
      end

      defp drop_nil_values(value) when is_map(value) do
        Enum.reduce(value, %{}, fn {key, nested}, acc ->
          case drop_nil_values(nested) do
            nil -> acc
            normalized -> Map.put(acc, key, normalized)
          end
        end)
      end

      defp drop_nil_values(value) when is_list(value) do
        Enum.map(value, &drop_nil_values/1)
      end

      defp drop_nil_values(value) do
        value
      end

      defp format_errors(changeset) do
        changeset
        |> traverse_errors(&translate_error/1)
        |> flatten_errors()
        |> Enum.join(", ")
      end

      defp flatten_errors(errors, prefix \\ nil)

      defp flatten_errors(errors, prefix) when is_map(errors) do
        Enum.flat_map(errors, fn {key, value} ->
          next_prefix =
            case prefix do
              nil -> to_string(key)
              current -> current <> "." <> to_string(key)
            end

          flatten_errors(value, next_prefix)
        end)
      end

      defp flatten_errors(errors, prefix) when is_list(errors) do
        Enum.map(errors, &(prefix <> " " <> &1))
      end

      defp translate_error({message, options}) do
        Enum.reduce(options, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", error_value_to_string(value))
        end)
      end

      defp error_value_to_string(value) when is_atom(value) do
        Atom.to_string(value)
      end

      defp error_value_to_string(value) do
        inspect(value)
      end
    end
  end
end
