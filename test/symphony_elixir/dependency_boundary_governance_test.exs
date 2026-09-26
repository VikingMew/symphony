defmodule SymphonyElixir.DependencyBoundaryGovernanceTest do
  use ExUnit.Case, async: true

  @dependency_classes %{
    runtime_framework: [:bandit, :ecto, :ecto_sql, :phoenix, :phoenix_html, :phoenix_live_view],
    data_format: [:jason, :solid, :yaml_elixir],
    boundary_transport: [:castore, :postgrex, :req],
    test_only: [:floki, :lazy_html],
    quality_tool: [:credo, :dialyxir]
  }

  @boundary_dependency_roots [CAStore, Postgrex, Req]
  @boundary_paths [
    "lib/mix/tasks/",
    "lib/symphony_elixir/database_setup.ex",
    "lib/symphony_elixir/github/",
    "lib/symphony_elixir/linear/",
    "lib/symphony_elixir/migration_check.ex",
    "lib/symphony_elixir/persistence.ex",
    "lib/symphony_elixir/persistence/",
    "lib/symphony_elixir/pr_review/store.ex",
    "lib/symphony_elixir/release.ex",
    "lib/symphony_elixir/repo.ex",
    "lib/symphony_elixir/sqlite_importer.ex",
    "lib/symphony_elixir/worker/client.ex"
  ]
  @global_state_owner_paths [
    "lib/symphony_elixir/cli.ex",
    "lib/symphony_elixir/http_server.ex",
    "lib/symphony_elixir/workflow.ex",
    "lib/symphony_elixir/workflow_store.ex"
  ]
  @global_write_calls [
    {Application, :delete_env},
    {Application, :put_env},
    {:persistent_term, :erase},
    {:persistent_term, :put},
    {Process, :register}
  ]

  test "every direct dependency has one declared boundary role" do
    declared = @dependency_classes |> Map.values() |> List.flatten()

    direct =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.map(&elem(&1, 0))

    assert Enum.sort(declared) == Enum.sort(direct)
    assert length(declared) == length(Enum.uniq(declared))
  end

  test "core modules do not reference boundary-only dependencies" do
    offenders =
      production_sources()
      |> Enum.reject(&boundary_path?/1)
      |> Enum.flat_map(fn path ->
        {module, ast} = source_module_and_ast(path)

        ast
        |> alias_references()
        |> Enum.filter(fn {dependency, _line} -> dependency in @boundary_dependency_roots end)
        |> Enum.map(fn {dependency, line} ->
          "#{path}:#{line}: #{inspect(module)} references #{inspect(dependency)}"
        end)
      end)

    assert offenders == []
  end

  test "global writes stay in declared startup and state-owner modules" do
    offenders =
      production_sources()
      |> Enum.reject(&(&1 in @global_state_owner_paths))
      |> Enum.flat_map(fn path ->
        {module, ast} = source_module_and_ast(path)

        ast
        |> remote_calls()
        |> Enum.filter(fn {owner, function, _line} -> {owner, function} in @global_write_calls end)
        |> Enum.map(fn {owner, function, line} ->
          "#{path}:#{line}: #{inspect(module)} calls #{inspect(owner)}.#{function}"
        end)
      end)

    assert offenders == []
  end

  defp production_sources do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp boundary_path?(path) do
    Enum.any?(@boundary_paths, fn boundary ->
      path == boundary or String.starts_with?(path, boundary)
    end)
  end

  defp source_module_and_ast(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

    module =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _meta, [{:__aliases__, _alias_meta, parts} | _rest]} = node, nil ->
          {node, Module.concat(parts)}

        node, module ->
          {node, module}
      end)
      |> elem(1)

    {module, ast}
  end

  defp alias_references(ast) do
    Macro.prewalk(ast, [], fn
      {:__aliases__, meta, parts} = node, references ->
        {node, [{Module.concat(parts), Keyword.fetch!(meta, :line)} | references]}

      node, references ->
        {node, references}
    end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp remote_calls(ast) do
    Macro.prewalk(ast, [], fn
      {{:., _dot_meta, [owner_ast, function]}, meta, _args} = node, calls when is_atom(function) ->
        case module_name(owner_ast) do
          nil -> {node, calls}
          owner -> {node, [{owner, function, Keyword.fetch!(meta, :line)} | calls]}
        end

      node, calls ->
        {node, calls}
    end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp module_name({:__aliases__, _meta, parts}), do: Module.concat(parts)
  defp module_name(name) when is_atom(name), do: name
  defp module_name(_ast), do: nil
end
