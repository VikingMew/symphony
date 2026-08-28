defmodule SymphonyElixir.WorkflowSettingsPackage do
  @moduledoc """
  Import, restore, and diff helpers for the split settings package.

  The Settings LiveView owns rendering and events. This module owns the
  workflow/profiles package semantics so import/export behavior can be tested
  without a LiveView process.
  """

  alias SymphonyElixir.{Workflow, WorkflowForm}

  @spec require_import_content(String.t() | nil) :: :ok | {:error, String.t()}
  def require_import_content(yaml) do
    if blank?(yaml), do: {:error, "Paste workflow.yml or profiles.yml before importing."}, else: :ok
  end

  @spec import_draft(String.t(), WorkflowForm.draft()) :: {:ok, String.t(), WorkflowForm.draft()} | {:error, term()}
  def import_draft(yaml, current) do
    with {:ok, parsed} <- Workflow.parse_settings_yaml(yaml) do
      do_import_draft(parsed, current)
    end
  end

  @spec stage_import(String.t(), WorkflowForm.draft(), keyword()) :: {:ok, map()} | {:error, term()}
  def stage_import(yaml, current, opts \\ []) do
    with {:ok, parsed} <- Workflow.parse_settings_yaml(yaml),
         {:ok, label, draft} <- do_import_draft(parsed, current) do
      type = package_type(parsed)

      {:ok,
       %{
         source: opts |> Keyword.get(:source, :paste) |> to_string(),
         detected_type: type,
         label: label,
         draft: draft,
         owning_tab: owning_tab(type),
         affected_areas: affected_areas(current, draft),
         diff: diff(current, draft),
         warnings: [],
         preview: preview(yaml)
       }}
    end
  end

  @spec changed?(String.t(), String.t()) :: boolean()
  def changed?(current_raw, next_raw) when is_binary(current_raw) and is_binary(next_raw) do
    not canonical_equal?(current_raw, next_raw)
  end

  def changed?(_current_raw, _next_raw), do: true

  @spec import_error_message(term()) :: String.t()
  def import_error_message(message) when is_binary(message), do: message
  def import_error_message(reason), do: inspect(reason)

  defp do_import_draft({:workflow, workflow_config}, current) do
    current_config = draft_config_or_base(current)

    loaded = %{
      config:
        workflow_config
        |> Map.delete("profiles")
        |> Map.put("profiles", Map.get(current_config, "profiles", %{})),
      prompt: Map.get(current, "prompt_body", "")
    }

    {:ok, "workflow.yml", WorkflowForm.from_loaded(loaded)}
  end

  defp do_import_draft({:profiles, profile_package}, current) do
    current_config = draft_config_or_base(current)

    loaded = %{
      config: Map.put(current_config, "profiles", Map.get(profile_package, :profiles, %{})),
      prompt: Map.get(profile_package, :base_prompt) || ""
    }

    {:ok, "profiles.yml", WorkflowForm.from_loaded(loaded)}
  end

  defp package_type({type, _package}), do: type
  defp owning_tab(:profiles), do: :agents
  defp owning_tab(_type), do: :workflow

  defp affected_areas(current, draft) do
    current
    |> diff(draft)
    |> Enum.map(& &1.area)
    |> Enum.uniq()
  end

  defp diff(current, draft) do
    current_flat = flatten(current)
    draft_flat = flatten(draft)

    (Map.keys(current_flat) ++ Map.keys(draft_flat))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&(Map.get(current_flat, &1) == Map.get(draft_flat, &1)))
    |> Enum.map(fn path ->
      %{
        area: diff_area(path),
        path: path,
        before: inspect_for_diff(Map.get(current_flat, path)),
        after: inspect_for_diff(Map.get(draft_flat, path))
      }
    end)
  end

  defp flatten(value), do: flatten_value(value, [])

  defp flatten_value(%{} = map, path) do
    Enum.flat_map(map, fn {key, value} -> flatten_value(value, path ++ [to_string(key)]) end)
    |> Map.new()
  end

  defp flatten_value(value, path), do: %{Enum.join(path, ".") => value}

  defp diff_area("prompt_body"), do: "Agents"
  defp diff_area("profiles." <> _rest), do: "Agents"
  defp diff_area("workspace_" <> _rest), do: "Runtime"
  defp diff_area("polling_" <> _rest), do: "Runtime"
  defp diff_area("agent_max_" <> _rest), do: "Runtime"
  defp diff_area("codex_" <> _rest), do: "Runtime"
  defp diff_area(_path), do: "Workflow"

  defp inspect_for_diff(nil), do: "n/a"
  defp inspect_for_diff(value) when is_binary(value), do: truncate(value, 600)
  defp inspect_for_diff(value), do: value |> inspect(limit: 12) |> truncate(600)

  defp preview(yaml), do: truncate(yaml, 4_000)

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit,
    do: binary_part(value, 0, limit) <> "\n... truncated"

  defp truncate(value, _limit), do: value

  defp draft_config_or_base(current) do
    case WorkflowForm.to_config(current) do
      {:ok, config} -> config
      {:error, _reason} -> Map.get(current, "_base_config", %{})
    end
  end

  defp canonical_equal?(left_raw, right_raw) do
    with {:ok, left} <- canonical_workflow(left_raw),
         {:ok, right} <- canonical_workflow(right_raw) do
      left == right
    else
      _ -> left_raw == right_raw
    end
  end

  defp canonical_workflow(raw) do
    with {:ok, workflow} <- Workflow.parse_content(raw),
         draft <- WorkflowForm.from_loaded(workflow),
         {:ok, config} <- WorkflowForm.to_config(draft) do
      {:ok, %{config: config, prompt: Map.get(draft, "prompt_body", "")}}
    end
  end

  defp blank?(value), do: SymphonyElixir.Text.blankish?(value)
end
