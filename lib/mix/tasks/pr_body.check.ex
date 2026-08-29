defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  @shortdoc "Validate PR body format against the docs-owned contract"
  @moduledoc """
  Validates a pull request description against `docs/pull-request-body.md`.

      mix pr_body.check --file /path/to/pr_body.md
  """

  @contract_paths ["docs/pull-request-body.md", "../docs/pull-request-body.md"]
  @entry_paths [".github/pull_request_template.md", "../.github/pull_request_template.md"]
  @start_marker "<!-- pr-body-template:start -->"
  @end_marker "<!-- pr-body-template:end -->"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] -> Mix.shell().info(@moduledoc)
      invalid != [] -> Mix.raise("Invalid option(s): #{inspect(invalid)}")
      true -> validate_file(required_opt(opts, :file))
    end
  end

  defp validate_file(file_path) do
    with {:ok, contract_path, contract} <- read_candidate(@contract_paths, "PR body contract"),
         {:ok, template} <- extract_template(contract, contract_path),
         {:ok, entry_path, entry} <- read_candidate(@entry_paths, "GitHub PR template"),
         :ok <- compare_templates(template, entry, contract_path, entry_path),
         {:ok, body} <- read_file(file_path),
         {:ok, headings} <- extract_headings(template, contract_path),
         :ok <- lint_and_print(contract_path, template, body, headings) do
      Mix.shell().info("PR body format OK")
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp read_candidate(paths, label) do
    case Enum.find_value(paths, &read_candidate_path/1) do
      nil -> {:error, "Unable to read #{label} from any of: #{Enum.join(paths, ", ")}"
      result -> result
    end
  end

  defp read_candidate_path(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, path, content}
      {:error, _reason} -> nil
    end
  end

  defp extract_template(contract, path) do
    with [_, rest] <- String.split(contract, @start_marker, parts: 2),
         [template, _] <- String.split(rest, @end_marker, parts: 2) do
      {:ok, String.trim(template)}
    else
      _ -> {:error, "Canonical template markers are missing or invalid in #{path}"}
    end
  end

  defp compare_templates(template, entry, contract_path, entry_path) do
    if String.trim(entry) == template,
      do: :ok,
      else: {:error, "#{entry_path} has drifted from the canonical template in #{contract_path}"}
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp extract_headings(template, path) do
    headings = Regex.scan(~r/^####\s+.+$/m, template) |> Enum.map(&hd/1)
    if headings == [], do: {:error, "No markdown headings found in #{path}"}, else: {:ok, headings}
  end

  defp lint_and_print(contract_path, template, body, headings) do
    errors = lint(template, body, headings)

    if errors == [] do
      :ok
    else
      Enum.each(errors, &Mix.shell().error("ERROR: #{&1}"))
      {:error, "PR body format invalid. Read `#{contract_path}` and follow it precisely."}
    end
  end

  defp lint(template, body, headings) do
    []
    |> check_required_headings(body, headings)
    |> check_order(body, headings)
    |> check_no_placeholders(body)
    |> check_sections(template, body, headings)
    |> check_closing_reference(body)
  end

  defp check_required_headings(errors, body, headings) do
    missing_errors =
      for heading <- headings, heading_position(body, heading) == :nomatch,
        do: "Missing required heading: #{heading}"

    errors ++ missing_errors
  end

  defp check_order(errors, body, headings) do
    positions = headings |> Enum.map(&heading_position(body, &1)) |> Enum.reject(&(&1 == :nomatch))
    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--"),
      do: errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."],
      else: errors
  end

  defp check_sections(errors, template, body, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = capture_section(template, heading)
      body_section = capture_section(body, heading)

      cond do
        is_nil(body_section) -> acc
        String.trim(body_section) == "" -> acc ++ ["Section cannot be empty: #{heading}"]
        true ->
          acc
          |> require_shape(heading, template_section, body_section, :bullet)
          |> require_shape(heading, template_section, body_section, :checkbox)
      end
    end)
  end

  defp require_shape(errors, heading, template, body, :bullet) do
    if Regex.match?(~r/^- /m, template) and not Regex.match?(~r/^- /m, body),
      do: errors ++ ["Section must include at least one bullet item: #{heading}"],
      else: errors
  end

  defp require_shape(errors, heading, template, body, :checkbox) do
    if Regex.match?(~r/^- \[ \] /m, template) and not Regex.match?(~r/^- \[[ xX]\] /m, body),
      do: errors ++ ["Section must include at least one checkbox item: #{heading}"],
      else: errors
  end

  defp check_closing_reference(errors, body) do
    matches = Regex.scan(~r/^Fixes [A-Z][A-Z0-9]+-\d+$/m, body) |> Enum.map(&hd/1)
    last_line = body |> String.trim() |> String.split("\n") |> List.last()

    cond do
      matches == [] -> errors ++ ["Missing exact Linear closing reference: Fixes <issue identifier>"]
      length(matches) != 1 -> errors ++ ["PR body must contain exactly one Linear closing reference."]
      last_line != hd(matches) -> errors ++ ["Linear closing reference must be the final independent line."]
      true -> errors
    end
  end

  defp heading_position(body, heading) do
    case :binary.match(body, heading) do
      {idx, _len} -> idx
      :nomatch -> :nomatch
    end
  end

  defp capture_section(doc, heading) do
    regex = ~r/^#{Regex.escape(heading)}\n\n(?<content>.*?)(?=^####\s|^Fixes\s|\z)/ms

    case Regex.named_captures(regex, doc) do
      %{"content" => content} -> content
      nil -> if(String.ends_with?(String.trim(doc), heading), do: "", else: nil)
    end
  end
end
