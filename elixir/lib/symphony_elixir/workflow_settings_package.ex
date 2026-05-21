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

  @spec restore_section(:workflow | :agents, WorkflowForm.draft(), WorkflowForm.draft()) :: WorkflowForm.draft()
  def restore_section(:agents, current, history) do
    current
    |> Map.put("prompt_body", Map.get(history, "prompt_body", ""))
    |> Map.put("profiles", Map.get(history, "profiles", %{}))
  end

  def restore_section(_workflow, current, history) do
    history
    |> Map.put("prompt_body", Map.get(current, "prompt_body", ""))
    |> Map.put("profiles", Map.get(current, "profiles", %{}))
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
