defmodule Mix.Tasks.Docs.Check do
  use Mix.Task

  @moduledoc "Validates indexed documentation frontmatter and code ownership anchors."
  @shortdoc "Validates documentation metadata"

  @docs_dir "docs"
  @index_path "docs/README.md"
  @genres ~w(spec architecture design reference guide roadmap meta)
  @statuses ~w(current superseded deprecated)
  @required ~w(title genre domain status language updated)

  @impl Mix.Task
  def run(_args) do
    index = File.read!(@index_path)
    anchors = load_anchors()
    documents = documents()

    results = Enum.map(documents, &check_document(&1, index, anchors))

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
    passed = Enum.count(results, &match?({:passed, _}, &1))
    skipped = Enum.count(results, &match?({:skipped, _}, &1))
    Mix.shell().info("docs.check: #{passed} passed, #{skipped} skipped, #{failures} failed")

    if failures > 0, do: Mix.raise("docs.check failed with #{failures} document(s)")
  end

  defp documents do
    Path.wildcard(Path.join(@docs_dir, "**/*.md"))
    |> Enum.reject(&String.starts_with?(&1, "docs/exec-plans/"))
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
