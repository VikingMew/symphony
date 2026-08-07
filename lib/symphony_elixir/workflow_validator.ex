defmodule SymphonyElixir.WorkflowValidator do
  @moduledoc """
  Validates raw workflow packages before they can replace runtime configuration.
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Config.Schema

  @type validation_result ::
          {:ok, %{workflow: Workflow.loaded_workflow(), settings: Schema.t()}}
          | {:error, {:workflow_validation_failed, String.t()}}

  @spec validate_raw(String.t()) :: validation_result()
  @spec validate_raw(String.t(), keyword()) :: validation_result()
  def validate_raw(raw_workflow_md, opts \\ []) when is_binary(raw_workflow_md) do
    with {:ok, workflow} <- parse_workflow(raw_workflow_md),
         {:ok, settings} <- parse_settings(workflow.config),
         :ok <- validate_semantics(settings, opts) do
      {:ok, %{workflow: workflow, settings: settings}}
    else
      {:error, {:workflow_validation_failed, _message} = reason} -> {:error, reason}
    end
  end

  @spec validate_version(map(), (map() -> String.t())) :: validation_result()
  def validate_version(version, exporter) when is_map(version) and is_function(exporter, 1) do
    version
    |> exporter.()
    |> validate_raw()
  end

  defp parse_workflow(raw_workflow_md) do
    case Workflow.parse_content(raw_workflow_md) do
      {:ok, workflow} ->
        {:ok, workflow}

      {:error, {:workflow_parse_error, reason}} ->
        {:error, {:workflow_validation_failed, "Failed to parse workflow YAML: #{format_reason(reason)}"}}

      {:error, reason} ->
        {:error, {:workflow_validation_failed, "Failed to parse workflow: #{inspect(reason)}"}}
    end
  end

  defp parse_settings(config) do
    case Schema.parse(config) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, {:invalid_workflow_config, message}} ->
        {:error, {:workflow_validation_failed, "Invalid workflow config: #{message}"}}
    end
  end

  defp validate_semantics(settings, opts) do
    if Keyword.get(opts, :runtime?, true) do
      case Config.validate_settings(settings) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, {:workflow_validation_failed, "Invalid workflow semantics: #{inspect(reason)}"}}
      end
    else
      :ok
    end
  end

  defp format_reason(%_{} = error), do: Exception.message(error)
end
