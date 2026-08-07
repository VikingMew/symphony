defmodule SymphonyElixir.ExecPlanIndex do
  @moduledoc """
  Validates the exec plan lifecycle index.
  """

  @type finding :: String.t()

  @spec validate(Path.t()) :: :ok | {:error, [finding()]}
  def validate(plans_dir) when is_binary(plans_dir) do
    readme_path = Path.join(plans_dir, "README.md")

    case File.read(readme_path) do
      {:ok, readme} ->
        findings =
          []
          |> check_lifecycle("active", readme, plan_files(plans_dir, "active"))
          |> check_lifecycle("completed", readme, plan_files(plans_dir, "completed"))
          |> check_root_plan_files(root_plan_files(plans_dir))
          |> check_duplicate_numbers(plan_paths(plans_dir))
          |> check_numbering_gaps(readme, plan_paths(plans_dir))
          |> Enum.reverse()

        if findings == [], do: :ok, else: {:error, findings}

      {:error, reason} ->
        {:error, ["Unable to read #{readme_path}: #{:file.format_error(reason)}"]}
    end
  end

  defp check_lifecycle(findings, lifecycle, readme, disk_files) do
    linked_files = linked_files(readme, lifecycle)

    missing_links =
      disk_files
      |> MapSet.difference(linked_files)
      |> MapSet.to_list()
      |> Enum.sort()

    stale_links =
      linked_files
      |> MapSet.difference(disk_files)
      |> MapSet.to_list()
      |> Enum.sort()

    findings
    |> add_finding(missing_links == [], "#{lifecycle} plan files missing from README: #{Enum.join(missing_links, ", ")}")
    |> add_finding(stale_links == [], "README references missing #{lifecycle} plan files: #{Enum.join(stale_links, ", ")}")
  end

  defp check_root_plan_files(findings, []), do: findings

  defp check_root_plan_files(findings, files) do
    [
      "Plan files must live under docs/exec-plans/active or docs/exec-plans/completed: #{Enum.join(files, ", ")}"
      | findings
    ]
  end

  defp check_duplicate_numbers(findings, paths) do
    duplicates =
      paths
      |> Enum.group_by(&plan_number/1)
      |> Enum.reject(fn {number, files} -> is_nil(number) or length(files) == 1 end)
      |> Enum.map(fn {number, files} -> "#{number}: #{Enum.join(Enum.sort(files), ", ")}" end)

    add_finding(findings, duplicates == [], "Plan numbers must be unique across active and completed: #{Enum.join(duplicates, "; ")}")
  end

  defp check_numbering_gaps(findings, readme, paths) do
    gaps = numbering_gaps(paths)
    normalized_readme = String.downcase(readme)

    undocumented =
      Enum.reject(gaps, fn number ->
        String.contains?(normalized_readme, "intentional numbering gaps") and
          String.contains?(readme, String.pad_leading(Integer.to_string(number), 3, "0"))
      end)

    add_finding(findings, undocumented == [], "Numbering gaps must be documented in README: #{format_numbers(undocumented)}")
  end

  defp add_finding(findings, true, _message), do: findings
  defp add_finding(findings, false, message), do: [message | findings]

  defp plan_files(plans_dir, lifecycle) do
    plans_dir
    |> Path.join(lifecycle)
    |> list_markdown_files()
    |> MapSet.new()
  end

  defp plan_paths(plans_dir) do
    ["active", "completed"]
    |> Enum.flat_map(fn lifecycle ->
      plans_dir
      |> Path.join(lifecycle)
      |> list_markdown_files()
      |> Enum.map(&Path.join(lifecycle, &1))
    end)
  end

  defp root_plan_files(plans_dir) do
    plans_dir
    |> list_markdown_files()
    |> Enum.filter(&Regex.match?(~r/^\d{3}-.*\.md$/, &1))
    |> Enum.sort()
  end

  defp list_markdown_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp linked_files(readme, lifecycle) do
    ~r/#{Regex.escape(lifecycle)}\/([^)\s]+\.md)/
    |> Regex.scan(readme)
    |> Enum.map(fn [_match, file] -> file end)
    |> MapSet.new()
  end

  defp numbering_gaps(paths) do
    numbers =
      paths
      |> Enum.map(&plan_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case numbers do
      [] ->
        []

      _ ->
        MapSet.difference(MapSet.new(Enum.min(numbers)..Enum.max(numbers)), MapSet.new(numbers))
        |> MapSet.to_list()
        |> Enum.sort()
    end
  end

  defp plan_number(path) do
    case path |> Path.basename() |> then(&Regex.run(~r/^(\d{3})-/, &1)) do
      [_match, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp format_numbers(numbers) do
    Enum.map_join(numbers, ", ", &String.pad_leading(Integer.to_string(&1), 3, "0"))
  end
end
