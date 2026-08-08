defmodule SymphonyElixir.Config.RuntimeResolver do
  @moduledoc """
  Runtime/environment resolution for parsed settings.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety

  @spec env_secret(String.t()) :: String.t() | nil
  def env_secret(env_name), do: normalize_secret_value(System.get_env(env_name))

  @spec resolve_secret_setting(term(), term()) :: String.t() | nil
  def resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  def resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  def resolve_secret_setting(_value, fallback), do: normalize_secret_value(fallback)

  @spec resolve_path_value(term(), String.t()) :: String.t()
  def resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing -> default
      "" -> default
      path -> path
    end
  end

  def resolve_path_value(_value, default), do: default

  @spec resolve_optional_path_value(term()) :: String.t() | nil
  def resolve_optional_path_value(value) when is_binary(value) do
    case normalize_path_token(value) do
      :missing -> nil
      "" -> nil
      path -> path
    end
  end

  def resolve_optional_path_value(_value), do: nil

  @spec default_workspace_root(term(), term()) :: term()
  def default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  def default_workspace_root(nil, fallback), do: fallback
  def default_workspace_root("", fallback), do: fallback
  def default_workspace_root(workspace, _fallback), do: workspace

  @spec expand_local_workspace_root(term()) :: String.t()
  def expand_local_workspace_root(workspace_root)
      when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  def expand_local_workspace_root(_workspace_root) do
    Schema.defaults()
    |> get_in(["workspace", "root"])
    |> Path.expand()
  end

  @spec default_turn_sandbox_policy(String.t()) :: map()
  def default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  @spec default_runtime_turn_sandbox_policy(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  def default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil
end
