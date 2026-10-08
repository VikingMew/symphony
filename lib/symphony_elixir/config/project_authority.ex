defmodule SymphonyElixir.Config.ProjectAuthority do
  @moduledoc """
  Defines the project-row-owned fields carried by portable workflow packages.
  """

  require Logger

  @fields [
    %{path: ["tracker", "project_slug"], project_field: :linear_project_slug, type: :string, default: nil},
    %{path: ["project", "repository_url"], project_field: :repository_url, type: :string, default: nil},
    %{path: ["project", "default_branch"], project_field: :default_branch, type: :string, default: "main"},
    %{path: ["project", "checkout_depth"], project_field: :checkout_depth, type: :integer, default: 1},
    %{path: ["project", "source_strategy"], project_field: :source_strategy, type: :string, default: "clone"},
    %{path: ["project", "worktree_fetch"], project_field: :worktree_fetch, type: :boolean, default: true},
    %{path: ["project", "worktree_cleanup"], project_field: :worktree_cleanup, type: :boolean, default: true}
  ]

  @type status :: :clean | :legacy_duplicate | :conflict
  @type diagnostic :: %{
          path: String.t(),
          effective_value: term(),
          carrier_value: term(),
          status: status()
        }
  @type conflict :: %{
          path: String.t(),
          installed_value: term(),
          package_value: term()
        }

  @spec strip(map()) :: map()
  def strip(config) when is_map(config) do
    Enum.reduce(@fields, config, fn %{path: path}, stripped -> delete_path(stripped, path) end)
  end

  @spec inject(map(), map()) :: map()
  def inject(config, project) when is_map(config) and is_map(project) do
    Enum.reduce(@fields, config, fn field, injected ->
      put_path(injected, field.path, effective_value(project, field))
    end)
  end

  @spec inherit_missing(map(), map()) :: map()
  def inherit_missing(config, source) when is_map(config) and is_map(source) do
    Enum.reduce(@fields, config, fn field, inherited ->
      case {fetch_path(inherited, field.path), fetch_path(source, field.path)} do
        {:error, {:ok, value}} -> put_path(inherited, field.path, value)
        _present_or_missing -> inherited
      end
    end)
  end

  @spec diagnostics(map(), map()) :: [diagnostic()]
  def diagnostics(project, config) when is_map(project) and is_map(config) do
    Enum.map(@fields, &diagnostic(project, config, &1))
  end

  @spec conflicts(map(), map()) :: [conflict()]
  def conflicts(project, config) when is_map(project) and is_map(config) do
    project
    |> diagnostics(config)
    |> Enum.filter(&(&1.status == :conflict))
    |> Enum.map(fn diagnostic ->
      %{
        path: diagnostic.path,
        installed_value: diagnostic.effective_value,
        package_value: diagnostic.carrier_value
      }
    end)
  end

  @spec carrier_values(map()) :: map()
  def carrier_values(config) when is_map(config) do
    Enum.reduce(@fields, %{}, fn field, values ->
      case fetch_path(config, field.path) do
        {:ok, carrier} -> Map.put(values, Enum.join(field.path, "."), normalize(carrier, field.type))
        :error -> values
      end
    end)
  end

  @spec warn_drift(map(), map()) :: :ok
  def warn_drift(project, config) when is_map(project) and is_map(config) do
    project
    |> diagnostics(config)
    |> Enum.reject(&(&1.status == :clean))
    |> Enum.each(fn diagnostic ->
      project_id = project_value(project, :id)
      project_slug = project_value(project, :slug)

      Logger.warning(
        "project_authority_drift project_id=#{project_id} project_slug=#{project_slug} field_path=#{diagnostic.path} status=#{diagnostic.status}",
        event: "workflow.project_authority_drift",
        operation: "compose_project_workflow",
        location: diagnostic.path,
        offending_value: %{
          project_id: project_id,
          project_slug: project_slug,
          carrier_value: diagnostic.carrier_value,
          status: diagnostic.status
        },
        expected_shape: "project-owned field absent from the durable workflow slice",
        error_code: "project_authority_drift",
        retryable: false
      )
    end)
  end

  defp diagnostic(project, config, field) do
    effective = effective_value(project, field)

    case fetch_path(config, field.path) do
      :error ->
        diagnostic(field.path, effective, nil, :clean)

      {:ok, carrier} ->
        carrier = normalize(carrier, field.type)
        status = if carrier == effective, do: :legacy_duplicate, else: :conflict
        diagnostic(field.path, effective, carrier, status)
    end
  end

  defp diagnostic(path, effective, carrier, status) do
    %{
      path: Enum.join(path, "."),
      effective_value: effective,
      carrier_value: carrier,
      status: status
    }
  end

  defp effective_value(project, field) do
    project
    |> project_value(field.project_field)
    |> default_value(field.default)
    |> normalize(field.type)
  end

  defp project_value(project, field) do
    Map.get(project, field, Map.get(project, Atom.to_string(field)))
  end

  defp default_value(nil, default), do: default
  defp default_value(value, _default), do: value

  defp normalize(value, :string) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _invalid -> value
    end
  end

  defp normalize("true", :boolean), do: true
  defp normalize("false", :boolean), do: false
  defp normalize(value, _type), do: value

  defp fetch_path(config, [key]) do
    if Map.has_key?(config, key), do: {:ok, Map.fetch!(config, key)}, else: :error
  end

  defp fetch_path(config, [key | rest]) do
    case Map.get(config, key) do
      nested when is_map(nested) -> fetch_path(nested, rest)
      _missing -> :error
    end
  end

  defp put_path(config, path, nil), do: delete_path(config, path)

  defp put_path(config, path, value) do
    put_in(config, Enum.map(path, &Access.key(&1, %{})), value)
  end

  defp delete_path(config, [key]) do
    Map.delete(config, key)
  end

  defp delete_path(config, [key | rest]) do
    case Map.get(config, key) do
      nested when is_map(nested) ->
        case delete_path(nested, rest) do
          empty when empty == %{} -> Map.delete(config, key)
          remaining -> Map.put(config, key, remaining)
        end

      _missing ->
        config
    end
  end
end
