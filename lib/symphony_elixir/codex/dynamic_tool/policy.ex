defmodule SymphonyElixir.Codex.DynamicTool.Policy do
  @moduledoc """
  Pure argument normalization and handoff helpers for Codex dynamic tools.
  """

  @spec normalize_update_arguments(term()) :: {:ok, map()} | {:error, term()}
  def normalize_update_arguments(arguments) when is_map(arguments) do
    payload =
      %{}
      |> put_optional_string(arguments, "description")
      |> put_optional_string(arguments, "comment")
      |> put_optional_string(arguments, "target_state")
      |> put_optional_map(arguments, "result")
      |> put_optional_map(arguments, "references")

    if map_size(payload) == 0, do: {:error, :empty_update}, else: {:ok, payload}
  catch
    {:invalid_field, field} -> {:error, {:invalid_field, field}}
  end

  def normalize_update_arguments(_arguments), do: {:error, :invalid_arguments}

  @spec implementation_completion_target?(String.t()) :: boolean()
  def implementation_completion_target?(target_state) when is_binary(target_state) do
    SymphonyElixir.StateName.normalize(target_state) ==
      SymphonyElixir.StateName.normalize("Ready to Merge")
  end

  @spec reference_link_candidates(map()) :: [map()]
  def reference_link_candidates(payload) do
    []
    |> collect_reference_links(Map.get(payload, "references"))
    |> collect_reference_links(Map.get(payload, "result"))
    |> dedupe_reference_links()
  end

  @spec pull_request_reference(map()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def pull_request_reference(payload) do
    references = Map.get(payload, "references", %{})

    pairs = [
      {"pr_url", "pr_proof", "references.pr_url/pr_proof"},
      {"pull_request", "pull_request_completion_proof", "references.pull_request/pull_request_completion_proof"}
    ]

    case Enum.find_value(pairs, &extract_reference_pair(references, &1)) do
      nil -> {:error, {:implementation_handoff_field_required, "references.pr_url/pr_proof"}}
      result -> result
    end
  end

  defp extract_reference_pair(references, {url_key, proof_key, _label}) do
    with url when is_binary(url) and url != "" <- Map.get(references, url_key),
         true <- Regex.match?(~r/\Ahttps:\/\/github\.com\/[^\/]+\/[^\/]+\/pull\/[1-9][0-9]*\z/, url),
         proof when is_binary(proof) and proof != "" <- Map.get(references, proof_key) do
      {:ok, url, proof}
    else
      _ -> nil
    end
  end

  defp put_optional_string(payload, arguments, field) do
    case SymphonyElixir.Payload.get_any(arguments, [field, argument_key(field)]) do
      nil -> payload
      value when is_binary(value) -> Map.put(payload, field, value)
      _ -> throw({:invalid_field, field})
    end
  end

  defp put_optional_map(payload, arguments, field) do
    case SymphonyElixir.Payload.get_any(arguments, [field, argument_key(field)]) do
      nil -> payload
      value when is_map(value) -> Map.put(payload, field, value)
      _ -> throw({:invalid_field, field})
    end
  end

  defp argument_key("description"), do: :description
  defp argument_key("comment"), do: :comment
  defp argument_key("target_state"), do: :target_state
  defp argument_key("result"), do: :result
  defp argument_key("references"), do: :references
  defp argument_key(_field), do: :__unknown_dynamic_tool_argument__

  defp collect_reference_links(links, value) when is_map(value) do
    Enum.reduce(value, links, fn
      {key, urls}, acc when key in ["urls", :urls] and is_list(urls) ->
        Enum.reduce(urls, acc, &maybe_add_reference_link(&2, "Reference", &1))

      {key, url}, acc ->
        maybe_add_reference_link(acc, reference_title(key), url)
    end)
  end

  defp collect_reference_links(links, _value), do: links

  defp maybe_add_reference_link(links, title, url) when is_binary(url) do
    if String.starts_with?(url, "https://") or String.starts_with?(url, "http://"),
      do: [%{title: title, url: url} | links],
      else: links
  end

  defp maybe_add_reference_link(links, _title, _url), do: links

  defp dedupe_reference_links(links), do: links |> Enum.reverse() |> Enum.uniq_by(& &1.url)

  defp reference_title(key) when key in ["pr_url", :pr_url, "pull_request_url", :pull_request_url], do: "Pull Request"
  defp reference_title(key) when key in ["commit_url", :commit_url], do: "Commit"
  defp reference_title(key) when key in ["branch_url", :branch_url], do: "Branch"
  defp reference_title(_key), do: "Reference"
end
