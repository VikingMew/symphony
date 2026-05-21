defmodule SymphonyElixir.Config.RuntimeResolverTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.RuntimeResolver

  @env_name "SYMPHONY_RUNTIME_RESOLVER_TEST_VALUE"
  @path_env_name "SYMPHONY_RUNTIME_RESOLVER_TEST_PATH"

  setup do
    previous_value = System.get_env(@env_name)
    previous_path = System.get_env(@path_env_name)

    on_exit(fn ->
      restore_env(@env_name, previous_value)
      restore_env(@path_env_name, previous_path)
    end)
  end

  test "resolves env-backed secret settings and blank secrets" do
    System.put_env(@env_name, "secret-value")

    assert RuntimeResolver.resolve_secret_setting("$#{@env_name}", "fallback") == "secret-value"
    assert RuntimeResolver.resolve_secret_setting("$MISSING_RUNTIME_RESOLVER_SECRET", "fallback") == "fallback"
    assert RuntimeResolver.resolve_secret_setting("", "fallback") == nil

    System.put_env(@env_name, "")
    assert RuntimeResolver.resolve_secret_setting("$#{@env_name}", "fallback") == nil
  end

  test "resolves required and optional path values from env references" do
    System.put_env(@path_env_name, "/tmp/symphony-runtime-resolver")

    assert RuntimeResolver.resolve_path_value("$#{@path_env_name}", "/fallback") == "/tmp/symphony-runtime-resolver"
    assert RuntimeResolver.resolve_path_value("$MISSING_RUNTIME_RESOLVER_PATH", "/fallback") == "/fallback"
    assert RuntimeResolver.resolve_optional_path_value("$#{@path_env_name}") == "/tmp/symphony-runtime-resolver"
    assert RuntimeResolver.resolve_optional_path_value("$MISSING_RUNTIME_RESOLVER_PATH") == nil
  end

  test "builds local and remote default turn sandbox policies" do
    root = File.cwd!()

    assert {:ok, local_policy} = RuntimeResolver.default_runtime_turn_sandbox_policy(root, [])
    assert local_policy["type"] == "workspaceWrite"
    assert local_policy["writableRoots"] == [Path.expand(root)]
    assert local_policy["networkAccess"] == false

    assert {:ok, remote_policy} = RuntimeResolver.default_runtime_turn_sandbox_policy("/remote/workspace", remote: true)
    assert remote_policy["writableRoots"] == ["/remote/workspace"]

    assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
             RuntimeResolver.default_runtime_turn_sandbox_policy(123, [])
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
