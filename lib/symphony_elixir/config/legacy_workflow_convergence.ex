defmodule SymphonyElixir.Config.LegacyWorkflowConvergence do
  @moduledoc """
  Builds the one-time instance candidate and project rewrite for legacy workflows.
  """

  alias SymphonyElixir.Config.WorkflowScopes
  alias SymphonyElixir.Workflow

  @hook_fields [
    {:after_create_hook, "after_create"},
    {:before_run_hook, "before_run"},
    {:after_run_hook, "after_run"},
    {:before_remove_hook, "before_remove"}
  ]

  @type legacy_row :: %{
          required(:workflow_id) => String.t(),
          required(:project_id) => String.t(),
          required(:project_slug) => String.t(),
          required(:yaml_config) => map(),
          required(:prompt_body) => String.t(),
          optional(atom()) => String.t() | nil
        }
  @type candidate :: %{
          required(:workflow_id) => String.t(),
          required(:project_id) => String.t(),
          required(:project_slug) => String.t(),
          required(:instance) => WorkflowScopes.instance_workflow(),
          required(:project_config) => map(),
          required(:raw_workflow_md) => String.t()
        }
  @type conflict :: %{
          required(String.t()) => [map()]
        }
  @type plan :: %{
          required(:candidates) => [candidate()],
          required(:setting) => :none | {:instance, map()} | {:conflict, conflict()}
        }
  @type status :: :zero | {:converged, WorkflowScopes.instance_workflow()} | {:conflict, conflict()}

  @spec plan([legacy_row()], boolean()) :: {:ok, plan()} | {:error, term()}
  def plan(rows, instance_exists?) when is_list(rows) and is_boolean(instance_exists?) do
    with {:ok, candidates} <- derive_candidates(rows) do
      {:ok,
       %{
         candidates: candidates,
         setting: setting(candidates, instance_exists?)
       }}
    end
  end

  @spec status(map() | nil, map() | nil) :: {:ok, status()} | {:error, term()}
  def status(instance_value, conflict_value) do
    case instance_value do
      nil -> conflict_status(conflict_value)
      value -> load_converged(value)
    end
  end

  @spec select_candidate(conflict(), String.t()) ::
          {:ok, WorkflowScopes.instance_workflow()} | {:error, {:invalid_selection, String.t()}}
  def select_candidate(%{"candidates" => candidates}, project_slug) when is_binary(project_slug) do
    case Enum.find(candidates, &(Map.fetch!(&1, "project_slug") == project_slug)) do
      nil -> {:error, {:invalid_selection, project_slug}}
      %{"candidate" => value} -> WorkflowScopes.load_instance(value)
    end
  end

  defp derive_candidates(rows) do
    rows
    |> Enum.sort_by(&{&1.project_slug, &1.project_id})
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, candidates} ->
      case candidate(row) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
        {:error, reason} -> {:halt, {:error, {:legacy_workflow, row.workflow_id, reason}}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      {:error, _reason} = error -> error
    end
  end

  defp candidate(row) do
    config = overlay_hooks(row.yaml_config, row)

    with {:ok, instance, project_config} <- WorkflowScopes.split_package(config, row.prompt_body) do
      {:ok,
       %{
         workflow_id: row.workflow_id,
         project_id: row.project_id,
         project_slug: row.project_slug,
         instance: instance,
         project_config: project_config,
         raw_workflow_md: Workflow.to_markdown(project_config, "")
       }}
    end
  end

  defp overlay_hooks(config, row) do
    Enum.reduce(@hook_fields, config, fn {field, hook}, config ->
      overlay_hook(config, hook, Map.get(row, field))
    end)
  end

  defp overlay_hook(config, _hook, nil), do: config

  defp overlay_hook(config, hook, value) when is_binary(value) do
    if String.trim(value) == "",
      do: config,
      else: put_in(config, [Access.key("hooks", %{}), hook], value)
  end

  defp setting(_candidates, true), do: :none
  defp setting([], false), do: :none

  defp setting(candidates, false) do
    case Enum.uniq_by(candidates, & &1.instance) do
      [candidate] -> {:instance, WorkflowScopes.dump_instance(candidate.instance)}
      _multiple -> {:conflict, conflict(candidates)}
    end
  end

  defp conflict(candidates) do
    %{
      "candidates" =>
        Enum.map(candidates, fn candidate ->
          %{
            "project_id" => candidate.project_id,
            "project_slug" => candidate.project_slug,
            "candidate" => WorkflowScopes.dump_instance(candidate.instance)
          }
        end),
      "differing_paths" => differing_paths(candidates)
    }
  end

  defp differing_paths(candidates) do
    flattened = Enum.map(candidates, &flatten_instance(&1.instance))
    paths = flattened |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(paths, fn path ->
      contributions =
        Enum.zip_with(candidates, flattened, fn candidate, values ->
          contribution(candidate, Map.fetch(values, path))
        end)

      if contributions |> Enum.map(&Map.take(&1, ["present", "value"])) |> Enum.uniq() |> length() > 1 do
        [%{"path" => path, "contributors" => contributions}]
      else
        []
      end
    end)
  end

  defp contribution(candidate, {:ok, value}) do
    %{
      "project_id" => candidate.project_id,
      "project_slug" => candidate.project_slug,
      "present" => true,
      "value" => value
    }
  end

  defp contribution(candidate, :error) do
    %{
      "project_id" => candidate.project_id,
      "project_slug" => candidate.project_slug,
      "present" => false
    }
  end

  defp flatten_instance(%{config: config, prompt_body: prompt_body}) do
    config
    |> flatten_map([], %{})
    |> Map.put("prompt_body", prompt_body)
  end

  defp flatten_map(map, [], flattened) when map_size(map) == 0, do: flattened

  defp flatten_map(map, path, flattened) when map_size(map) == 0 do
    Map.put(flattened, Enum.join(path, "."), map)
  end

  defp flatten_map(map, path, flattened) do
    Enum.reduce(map, flattened, fn {key, value}, flattened ->
      next_path = path ++ [to_string(key)]

      if is_map(value) do
        flatten_map(value, next_path, flattened)
      else
        Map.put(flattened, Enum.join(next_path, "."), value)
      end
    end)
  end

  defp conflict_status(nil), do: {:ok, :zero}

  defp conflict_status(%{"candidates" => _candidates, "differing_paths" => _paths} = conflict),
    do: {:ok, {:conflict, conflict}}

  defp load_converged(value) do
    case WorkflowScopes.load_instance(value) do
      {:ok, instance} -> {:ok, {:converged, instance}}
      {:error, _reason} = error -> error
    end
  end
end
