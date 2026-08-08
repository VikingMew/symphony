defmodule SymphonyElixirWeb.AdminLive.WorkflowState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias SymphonyElixir.{
    PersistenceProvider,
    WorkflowForm,
    WorkflowSettingsPackage,
    WorkflowStore,
    WorkflowValidator
  }

  alias SymphonyElixirWeb.Admin.{ProjectSettings, SettingsCheck}
  alias SymphonyElixirWeb.AdminLive.{SettingsShell, State}

  @workflow_settings_source "web_workflow_settings"
  @agent_settings_source "web_agent_settings"

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

  @spec save(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def save(params, socket) do
    draft = workflow_draft(socket, params) |> ProjectSettings.apply_to_workflow_draft(socket.assigns.default_project)
    section = SettingsShell.tab(socket.assigns.live_action)
    project = socket.assigns.selected_project

    socket =
      if is_nil(project) do
        put_flash(socket, :error, "No project is configured yet. Configure a project in Settings / Projects first.")
      else
        with {:ok, raw} <- WorkflowForm.to_raw(draft),
             :changed <- workflow_change_status(raw, socket),
             {:ok, version} <- safe_import_workflow(project, raw, settings_source(section)) do
          _ = WorkflowStore.force_reload()

          socket
          |> put_flash(:info, "#{section_label(section)} saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
          |> assign_save_notice(:success, "#{section_label(section)} saved", "Version #{version.version} is active. Runtime workflow refreshed.")
          |> assign(:workflow_diagnostics_notice, "#{section_label(section)} saved. Runtime workflow refreshed. Re-run Linear diagnostics.")
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_form, draft)
          |> assign(:workflow_form_dirty?, false)
          |> assign_validation(draft)
          |> State.refresh()
        else
          :unchanged ->
            socket
            |> put_flash(:info, "#{section_label(section)} already up to date.")
            |> assign_save_notice(:info, "#{section_label(section)} already up to date", "No changes to save.")
            |> assign(:workflow_validation_visible?, true)
            |> assign(:workflow_form, draft)
            |> assign(:workflow_form_dirty?, false)
            |> assign_validation(draft)

          {:error, message} when is_binary(message) ->
            socket
            |> put_flash(:error, "#{section_label(section)} rejected: #{message}")
            |> assign_save_notice(:error, "#{section_label(section)} save failed", "Fix highlighted fields before saving.")
            |> assign(:workflow_validation_visible?, true)
            |> assign(:workflow_form, draft)
            |> assign(:workflow_form_dirty?, true)
            |> assign(:workflow_field_errors, WorkflowForm.field_errors(draft))
            |> assign(:workflow_validation_error, nil)
            |> assign(:workflow_form_valid?, false)

          {:error, reason} ->
            message = inspect(reason)

            socket
            |> put_flash(:error, "#{section_label(section)} rejected: #{message}")
            |> assign_save_notice(:error, "#{section_label(section)} save failed", message)
            |> assign(:workflow_validation_visible?, true)
            |> assign(:workflow_field_errors, %{})
            |> assign(:workflow_form, draft)
            |> assign(:workflow_form_dirty?, true)
        end
      end

    {:noreply, socket}
  end

  @spec restore(String.t(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def restore(id, socket) do
    section = SettingsShell.tab(socket.assigns.live_action)
    version = Enum.find(section_versions(socket.assigns.workflow_versions, section), &(&1.id == id))
    project = socket.assigns.selected_project

    socket =
      if is_nil(project) do
        put_flash(socket, :error, "No project is configured yet. Configure a project in Settings / Projects first.")
      else
        with %{} = version <- version,
             raw when is_binary(raw) <- persistence().export_workflow(version),
             {:ok, history_draft} <- WorkflowForm.from_raw(raw),
             draft <- WorkflowSettingsPackage.restore_section(section, socket.assigns.workflow_form, history_draft),
             draft <- ProjectSettings.apply_to_workflow_draft(draft, socket.assigns.default_project),
             {:ok, restored_raw} <- WorkflowForm.to_raw(draft),
             {:ok, restored_version} <- safe_import_workflow(project, restored_raw, settings_source(section)) do
          _ = WorkflowStore.force_reload()

          socket
          |> put_flash(:info, "#{section_label(section)} restored. Runtime workflow refreshed. Re-run Linear diagnostics.")
          |> assign_save_notice(:success, "#{section_label(section)} restored", "Version #{restored_version.version} is active. Runtime workflow refreshed.")
          |> assign(:workflow_diagnostics_notice, "#{section_label(section)} restored. Runtime workflow refreshed. Re-run Linear diagnostics.")
          |> assign(:workflow_validation_visible?, true)
          |> assign(:workflow_form, draft)
          |> assign(:workflow_form_dirty?, false)
          |> assign_validation(draft)
          |> State.refresh()
        else
          nil ->
            put_flash(socket, :error, "Settings version not found")

          {:error, message} when is_binary(message) ->
            socket
            |> put_flash(:error, "Settings restore rejected: #{message}")
            |> assign_save_notice(:error, "Settings restore failed", message)
            |> assign(:workflow_validation_visible?, true)
            |> assign(:workflow_validation_error, message)

          {:error, reason} ->
            message = inspect(reason)

            socket
            |> put_flash(:error, "Settings restore rejected: #{message}")
            |> assign_save_notice(:error, "Settings restore failed", message)
            |> assign(:workflow_validation_visible?, true)
            |> assign(:workflow_validation_error, message)
        end
      end

    {:noreply, socket}
  end

  @spec add_transition(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def add_transition(socket) do
    draft =
      socket.assigns
      |> Map.get(:workflow_form, %{})
      |> append_empty_transition()

    {:noreply,
     socket
     |> assign(:workflow_save_notice, nil)
     |> assign(:workflow_validation_visible?, true)
     |> assign(:workflow_form, draft)
     |> assign(:workflow_form_dirty?, true)
     |> assign_validation(draft)}
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

  @spec load_form(map() | nil, term()) :: {map(), boolean()}
  def load_form(nil, {:ok, %{workflow: workflow}}) do
    if Map.get(workflow, :setup_required, false) do
      {WorkflowForm.empty(), true}
    else
      {WorkflowForm.from_loaded(workflow), false}
    end
  end

  def load_form(version, _runtime) do
    version
    |> persistence().export_workflow()
    |> WorkflowForm.from_raw()
    |> case do
      {:ok, draft} -> {draft, false}
      {:error, _reason} -> {WorkflowForm.empty(), false}
    end
  end

  @spec refreshed_form(Phoenix.LiveView.Socket.t(), map()) :: map()
  def refreshed_form(socket, loaded_workflow_form) do
    if Map.get(socket.assigns, :workflow_form_dirty?, false) do
      Map.get(socket.assigns, :workflow_form, loaded_workflow_form)
    else
      loaded_workflow_form
    end
  end

  @spec section_versions([map()], atom()) :: [map()]
  def section_versions(versions, section) do
    Enum.filter(versions, &(settings_version_section(&1) == section))
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

  defp append_empty_transition(draft) do
    transitions =
      draft
      |> Map.get("allowed_transitions", [])
      |> normalize_transition_entries()
      |> Kernel.++([%{"from" => "", "to" => "", "actor" => "", "profile" => ""}])

    Map.put(draft, "allowed_transitions", transitions)
  end

  defp normalize_transition_entries(entries) when is_list(entries), do: entries

  defp normalize_transition_entries(entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {index, _entry} ->
      case Integer.parse(to_string(index)) do
        {integer, ""} -> integer
        _ -> 0
      end
    end)
    |> Enum.map(fn {_index, entry} -> entry end)
  end

  defp normalize_transition_entries(_entries), do: []

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

  defp settings_source(:agents), do: @agent_settings_source
  defp settings_source(_section), do: @workflow_settings_source

  defp settings_version_section(version) do
    atom_source = Map.get(version, :source)

    case atom_source || Map.get(version, "source") do
      @agent_settings_source -> :agents
      @workflow_settings_source -> :workflow
      _source -> nil
    end
  end

  defp safe_import_workflow(project, raw, source) do
    persistence().import_workflow(project, raw, source)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp workflow_change_status(raw, socket) do
    case Map.get(socket.assigns, :active_workflow_version) do
      nil ->
        :changed

      version ->
        current_raw = persistence().export_workflow(version)
        if WorkflowSettingsPackage.changed?(current_raw, raw), do: :changed, else: :unchanged
    end
  end

  defp persistence, do: PersistenceProvider.module()
end
