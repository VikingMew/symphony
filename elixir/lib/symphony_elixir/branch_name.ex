defmodule SymphonyElixir.BranchName do
  @moduledoc """
  Validation for Linear-provided git branch names.
  """

  @unsafe_fragments ["..", "@{", "\\", "~", "^", ":", "?", "*", "["]

  @spec validate(term()) :: {:ok, String.t()} | {:error, term()}
  def validate(branch) when is_binary(branch) do
    branch = String.trim(branch)

    case validation_error(branch) do
      nil -> {:ok, branch}
      :missing_linear_branch_name -> {:error, :missing_linear_branch_name}
      reason -> {:error, {:invalid_linear_branch_name, reason}}
    end
  end

  def validate(_branch), do: {:error, :missing_linear_branch_name}

  defp validation_error(""), do: :missing_linear_branch_name

  defp validation_error(branch) do
    Enum.find_value(validation_rules(), & &1.(branch))
  end

  defp validation_rules do
    [
      fn branch -> if not ascii?(branch), do: :non_ascii end,
      fn branch -> if String.match?(branch, ~r/\s/), do: :whitespace end,
      fn branch -> if String.starts_with?(branch, "-"), do: :leading_dash end,
      fn branch -> if String.starts_with?(branch, "/") or String.ends_with?(branch, "/"), do: :slash_boundary end,
      fn branch -> if String.ends_with?(branch, "."), do: :trailing_dot end,
      fn branch -> if String.contains?(branch, "//"), do: :double_slash end,
      &unsafe_fragment/1,
      fn branch -> if String.upcase(branch) == "HEAD", do: :reserved end
    ]
  end

  defp unsafe_fragment(branch) do
    case Enum.find(@unsafe_fragments, &String.contains?(branch, &1)) do
      nil -> nil
      fragment -> {:unsafe_fragment, fragment}
    end
  end

  defp ascii?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in 1..127))
  end
end
