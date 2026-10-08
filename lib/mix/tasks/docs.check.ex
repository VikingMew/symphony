defmodule Mix.Tasks.Docs.Check do
  use Mix.Task

  @moduledoc """
  Validates indexed documentation metadata and the deterministic D-group contract owned by
  `docs/documentation-system-design.md`.
  """
  @shortdoc "Validates documentation metadata"

  @docs_dir "docs"
  @index_path "docs/README.md"
  @genres ~w(spec architecture design reference guide roadmap meta)
  @statuses ~w(current superseded deprecated)
  @required ~w(title genre domain status language updated)
  @agents_path "AGENTS.md"
  @readme_path "README.md"
  @workflow_path ".github/workflows/make-all.yml"
  @quality_commands ~w(scripts/quality.sh)
  @scripts ~w(scripts/setup.sh scripts/quality.sh scripts/check.sh scripts/unit.sh scripts/dialyzer.sh)

  @impl Mix.Task
  def run(_args) do
    index = File.read!(@index_path)
    anchors = load_anchors()
    documents = documents()
    d_findings = d_findings()

    results = Enum.map(documents, &check_document(&1, index, anchors))

    Enum.each(d_findings, &Mix.shell().error("FAIL #{&1}"))

    Enum.each(results, fn
      {:passed, path} ->
        Mix.shell().info("PASS #{path}")

      {:skipped, path} ->
        Mix.shell().info("SKIP #{path} (no frontmatter)")

      {:failed, path, findings} ->
        Mix.shell().error("FAIL #{path}")
        Enum.each(findings, &Mix.shell().error("  - #{&1}"))
    end)

    failures = Enum.count(results, &match?({:failed, _, _}, &1))
    d_failures = length(d_findings)
    passed = Enum.count(results, &match?({:passed, _}, &1))
    skipped = Enum.count(results, &match?({:skipped, _}, &1))
    Mix.shell().info("docs.check: #{passed} passed, #{skipped} skipped, #{failures} failed")

    if failures + d_failures > 0 do
      Mix.raise("docs.check failed with #{failures} document(s) and #{d_failures} D-group violation(s)")
    end

    Mix.shell().info("D baseline: 0 remaining")
    nil
  end

  defp d_findings do
    agents_findings() ++ script_findings() ++ workflow_findings() ++ readme_findings()
  end

  defp agents_findings do
    if File.regular?(@agents_path) do
      content = File.read!(@agents_path)
      commands = content |> section("## Quality Gates") |> backtick_commands()

      if commands == @quality_commands do
        []
      else
        [
          "D-03 #{@agents_path} target=Quality Gates commands " <>
            "expected=#{inspect(@quality_commands)} actual=#{inspect(commands)}"
        ]
      end
    else
      ["D-01 #{@agents_path} target=repository governance file expected=regular file actual=missing"]
    end
  end

  defp script_findings do
    Enum.flat_map(@scripts, fn path ->
      cond do
        not File.regular?(path) ->
          ["D-03 #{path} target=quality gate script expected=regular executable file actual=missing"]

        executable?(path) ->
          []

        true ->
          ["D-03 #{path} target=quality gate script expected=executable actual=not executable"]
      end
    end)
  end

  defp workflow_findings do
    actual = workflow_commands()
    expected = ~w(scripts/quality.sh scripts/setup.sh)

    if actual == expected do
      []
    else
      [
        "D-03 #{@workflow_path} target=jobs.*.steps.run " <>
          "expected=#{inspect(expected)} actual=#{inspect(actual)}"
      ]
    end
  end

  defp readme_findings do
    if File.regular?(@readme_path) do
      content = File.read!(@readme_path)

      [
        readme_section_finding(content, "## Project Layout", "structure or module map"),
        readme_command_finding(content, "## Quick Start", "scripts/setup.sh", "startup entry command"),
        readme_command_finding(content, "## Development", "mise exec -- mix test", "development entry command")
      ]
      |> Enum.reject(&is_nil/1)
    else
      ["D-04 #{@readme_path} target=project guide expected=regular file actual=missing"]
    end
  end

  defp readme_section_finding(content, heading, target) do
    if section(content, heading) == "" do
      "D-04 #{@readme_path} target=#{target} expected=#{inspect(heading)} section actual=missing"
    end
  end

  defp readme_command_finding(content, heading, command, target) do
    actual = section(content, heading)

    if not String.contains?(actual, command) do
      "D-04 #{@readme_path} target=#{target} expected=#{inspect(command)} in #{heading} actual=missing"
    end
  end

  defp workflow_commands do
    case YamlElixir.read_from_file(@workflow_path) do
      {:ok, %{"jobs" => jobs}} when is_map(jobs) ->
        jobs
        |> Map.values()
        |> Enum.flat_map(&Map.get(&1, "steps", []))
        |> Enum.map(&Map.get(&1, "run"))
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, "scripts/"))
        |> Enum.sort()

      _other ->
        []
    end
  end

  defp section(content, heading) do
    content
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.drop_while(&(&1 != heading))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.join("\n")
  end

  defp backtick_commands(content) do
    ~r/`(scripts\/[^`]+\.sh)`/
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
  end

  defp executable?(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o111) != 0
  end

  defp documents do
    Path.wildcard(Path.join(@docs_dir, "**/*.md"))
    |> Enum.sort()
  end

  defp check_document(path, index, anchors) do
    content = File.read!(path)

    case frontmatter(content) do
      :missing ->
        {:skipped, path}

      {:error, reason} ->
        {:failed, path, [reason]}

      {:ok, metadata} ->
        findings = validate_metadata(metadata, path, index, anchors)

        if findings == [], do: {:passed, path}, else: {:failed, path, findings}
    end
  end

  defp frontmatter(content) do
    # NOTE: do NOT use ~r/\R/ here — \R matches U+0085 (NEL), which appears inside
    # UTF-8 multi-byte characters (e.g. "配" = E9 85 8D) and would split them.
    case String.split(content, ~r/\r?\n/, trim: false) do
      ["---" | lines] -> parse_frontmatter(lines)
      _lines -> :missing
    end
  end

  defp parse_frontmatter(lines) do
    {metadata_lines, rest} = Enum.split_while(lines, &(&1 != "---"))

    case rest do
      ["---" | _body] -> parse_metadata_lines(metadata_lines)
      [] -> {:error, "frontmatter is missing its closing --- delimiter"}
    end
  end

  defp parse_metadata_lines(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, metadata} ->
      trimmed = String.trim(line)

      if trimmed == "" or String.starts_with?(trimmed, "#") do
        {:cont, {:ok, metadata}}
      else
        parse_metadata_line(line, metadata)
      end
    end)
  end

  defp parse_metadata_line(line, metadata) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)

        if key == "" or Map.has_key?(metadata, key) do
          {:halt, {:error, "invalid or duplicate frontmatter key in: #{line}"}}
        else
          {:cont, {:ok, Map.put(metadata, key, value)}}
        end

      _other ->
        {:halt, {:error, "unparseable frontmatter line: #{line}"}}
    end
  end

  defp validate_metadata(metadata, path, index, anchors) do
    required =
      Enum.flat_map(@required, fn field ->
        if metadata[field] in [nil, ""], do: ["missing required field: #{field}"], else: []
      end)

    values =
      [{"genre", @genres}, {"status", @statuses}]
      |> Enum.flat_map(fn {field, allowed} ->
        value = metadata[field]
        if value in [nil, ""] or value in allowed, do: [], else: ["invalid #{field}: #{value}"]
      end)

    basename = Path.basename(path)

    registration =
      if String.contains?(index, basename),
        do: [],
        else: ["not registered in #{@index_path}: #{basename}"]

    required ++ values ++ registration ++ owner_findings(metadata, anchors)
  end

  defp owner_findings(%{"genre" => genre} = metadata, anchors)
       when genre in ["reference", "spec"] do
    owner = metadata["owner"]

    cond do
      owner in [nil, ""] -> ["missing required field: owner"]
      not String.contains?(anchors, owner) -> ["owner not found under lib/: #{owner}"]
      true -> []
    end
  end

  defp owner_findings(_metadata, _anchors), do: []

  defp load_anchors do
    Path.wildcard("lib/**/*.ex")
    |> Enum.map_join("\n", &File.read!/1)
  end
end
