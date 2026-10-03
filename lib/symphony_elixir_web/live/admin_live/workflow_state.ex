defmodule SymphonyElixirWeb.AdminLive.WorkflowState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias SymphonyElixir.{
    PersistenceProvider,
    WorkflowForm,
    WorkflowValidator
  }

  alias SymphonyElixirWeb.Admin.{ProjectSettings, SettingsCheck}
  alias SymphonyElixirWeb.AdminLive.Settings.Components

  @spec validate(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def validate(params, socket) do
    draft = workflow_draft(socket, params)

    {:noreply,
     socket
     |> assign(:workflow_save_notice, nil)
     |> assign(:workflow_validation_visible?, true)
     |> assign(:workflow_form, draft)
     |> assign(:workflow_form_dirty?, true)
     |> assign_validation(draft)}
  end

  @spec save(map(), Phoenix.LiveView.Socket.t()) ::
          {:saved, Phoenix.LiveView.Socket.t()}
          | {:unchanged, Phoenix.LiveView.Socket.t()}
          | {:error, Phoenix.LiveView.Socket.t()}
  def save(params, socket) do
    draft = workflow_draft(socket, params)
    section = Components.tab(socket.assigns.live_action)

    with {:ok, instance} <- WorkflowForm.to_instance_scope(draft),
         :changed <- instance_change_status(instance, socket),
         {:ok, _instance} <- persist_instance(instance) do
      refreshed_projects = enabled_project_names(socket.assigns.projects)
      refresh_message = instance_refresh_message(refreshed_projects)

      {:saved,
       socket
       |> put_flash(:info, "#{section_label(section)} saved to the instance singleton. #{refresh_message}")
       |> assign_save_notice(
         :success,
         "#{section_label(section)} saved installation-wide",
         "Instance singleton updated. #{refresh_message}"
       )
       |> assign(
         :workflow_diagnostics_notice,
         "#{section_label(section)} saved to the instance singleton. #{refresh_message}"
       )
       |> assign(:workflow_validation_visible?, true)
       |> assign(:workflow_form, draft)
       |> assign(:workflow_form_dirty?, false)
       |> assign_validation(draft)}
    else
      :unchanged ->
        {:unchanged,
         socket
         |> put_flash(:info, "#{section_label(section)} already up to date.")
         |> assign_save_notice(:info, "#{section_label(section)} already up to date", "No instance changes to save.")
         |> assign(:workflow_validation_visible?, true)
         |> assign(:workflow_form, draft)
         |> assign(:workflow_form_dirty?, false)
         |> assign_validation(draft)}

      {:error, message} when is_binary(message) ->
        {:error,
         socket
         |> put_flash(:error, "#{section_label(section)} rejected: #{message}")
         |> assign_save_notice(:error, "#{section_label(section)} save failed", "Fix highlighted fields before saving.")
         |> assign(:workflow_validation_visible?, true)
         |> assign(:workflow_form, draft)
         |> assign(:workflow_form_dirty?, true)
         |> assign(:workflow_field_errors, WorkflowForm.field_errors(draft))
         |> assign(:workflow_validation_error, nil)
         |> assign(:workflow_form_valid?, false)}

      {:error, reason} ->
        message = inspect(reason)

        {:error,
         socket
         |> put_flash(:error, "#{section_label(section)} rejected: #{message}")
         |> assign_save_notice(:error, "#{section_label(section)} save failed", message)
         |> assign(:workflow_validation_visible?, true)
         |> assign(:workflow_field_errors, %{})
         |> assign(:workflow_form, draft)
         |> assign(:workflow_form_dirty?, true)}
    end
  end

  @spec assign_validation(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_validation(socket, draft) do
    field_errors = WorkflowForm.field_errors(draft)

    if field_errors == %{},
      do: assign_semantic_validation(socket, draft),
      else: assign_field_validation(socket, draft, field_errors)
  end

  @spec assign_save_notice(Phoenix.LiveView.Socket.t(), atom(), String.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def assign_save_notice(socket, level, title, message) do
    assign(socket, :workflow_save_notice, %{level: level, title: title, message: message})
  end

  @spec reconcile_legacy_instance(Phoenix.LiveView.Socket.t()) ::
          {:saved, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def reconcile_legacy_instance(socket) do
    case socket.assigns.explicit_project do
      nil ->
        {:error,
         assign(socket, :legacy_reconciliation_notice, %{
           level: :error,
           title: "Source project required",
           message: "Select a contributing project before reconciling legacy instance settings."
         })}

      project ->
        slug = ProjectSettings.value(project, :slug)

        case persistence().reconcile_legacy_instance_workflow(slug) do
          {:ok, {result, _instance}} when result in [:converged, :already_converged] ->
            {:saved,
             assign(socket, :legacy_reconciliation_notice, %{
               level: :success,
               title: "Legacy instance settings reconciled",
               message: "#{slug} was used as the explicit source (#{result}). Runtime configuration refreshed."
             })}

          {:error, reason} ->
            {:error,
             assign(socket, :legacy_reconciliation_notice, %{
               level: :error,
               title: "Legacy reconciliation failed",
               message: inspect(reason)
             })}
        end
    end
  end

  @spec load_instance_form(map() | nil) :: map()
  def load_instance_form(nil), do: WorkflowForm.empty()

  def load_instance_form(%{config: config, prompt_body: prompt_body}) do
    WorkflowForm.from_loaded(%{config: config, prompt: prompt_body})
  end

  @spec refreshed_form(Phoenix.LiveView.Socket.t(), map()) :: map()
  def refreshed_form(socket, loaded_workflow_form) do
    if Map.get(socket.assigns, :workflow_form_dirty?, false) do
      Map.get(socket.assigns, :workflow_form, loaded_workflow_form)
    else
      loaded_workflow_form
    end
  end

  @spec section_label(atom()) :: String.t()
  def section_label(:agents), do: "Agent settings"
  def section_label(_section), do: "Workflow settings"

  defp workflow_draft(socket, params) do
    current = Map.get(socket.assigns, :workflow_form, %{})
    base_config = Map.get(current, "_base_config", %{})

    current
    |> deep_merge(params)
    |> Map.put("_base_config", base_config)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value), do: deep_merge(left_value, right_value), else: right_value
    end)
  end

  defp assign_field_validation(socket, draft, field_errors) do
    socket
    |> assign(:workflow_field_errors, field_errors)
    |> assign(:workflow_check_targets, [])
    |> assign(:workflow_validation_error, nil)
    |> assign(:workflow_form_valid?, false)
    |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
  end

  defp assign_semantic_validation(socket, draft) do
    with {:ok, raw} <- WorkflowForm.to_raw(draft),
         {:ok, _validation} <- WorkflowValidator.validate_raw(raw, runtime?: false) do
      socket
      |> assign(:workflow_field_errors, %{})
      |> assign(:workflow_check_targets, [])
      |> assign(:workflow_validation_error, nil)
      |> assign(:workflow_form_valid?, true)
      |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
    else
      {:error, {:workflow_validation_failed, message}} -> assign_semantic_error(socket, draft, message)
      {:error, message} -> assign_semantic_error(socket, draft, message)
    end
  end

  defp assign_semantic_error(socket, draft, message) do
    socket
    |> assign(:workflow_field_errors, %{})
    |> assign(:workflow_check_targets, SettingsCheck.workflow_check_targets(draft, message))
    |> assign(:workflow_validation_error, message)
    |> assign(:workflow_form_valid?, false)
    |> assign(:workflow_form_summary, WorkflowForm.summary(draft))
  end

  defp persist_instance(%{config: config, prompt_body: prompt_body}) do
    config
    |> persistence().put_instance_workflow(prompt_body)
    |> PersistenceProvider.publish_runtime_mutation()
  end

  defp instance_change_status(instance, socket) do
    if Map.get(socket.assigns, :current_instance_workflow) == instance,
      do: :unchanged,
      else: :changed
  end

  defp enabled_project_names(projects) do
    projects
    |> Enum.filter(&(ProjectSettings.value(&1, :enabled) == true))
    |> Enum.map(&ProjectSettings.value(&1, :name))
  end

  defp instance_refresh_message([]), do: "No enabled project snapshots required refresh."

  defp instance_refresh_message(projects) do
    "Future runtime snapshots refreshed for enabled projects: #{Enum.join(projects, ", ")}."
  end

  defp persistence, do: PersistenceProvider.module()
end
