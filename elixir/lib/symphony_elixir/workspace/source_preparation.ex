defmodule SymphonyElixir.Workspace.SourcePreparation do
  @moduledoc """
  Project source preparation policy for clone/worktree workspace layouts.

  `SymphonyElixir.Workspace` still executes hooks and git commands, but this
  module owns the source-preparation naming/layout decisions so they are not
  embedded in the generic workspace lifecycle.
  """

  @spec repository_cache_path(map()) :: Path.t()
  def repository_cache_path(settings) do
    settings
    |> repository_base_root()
    |> Path.join(repository_cache_key(settings.project))
    |> Path.expand()
  end

  @spec repository_base_root(map()) :: Path.t()
  def repository_base_root(settings) do
    case settings.workspace.repository_base_root do
      root when is_binary(root) and root != "" -> root
      _ -> Path.join(settings.workspace.root, "repositories")
    end
  end

  @spec worktree_base_root(map()) :: Path.t()
  def worktree_base_root(settings) do
    case settings.workspace.worktree_base_root do
      root when is_binary(root) and root != "" -> root
      _ -> Path.join(settings.workspace.root, "worktrees")
    end
  end

  @spec worktree_branch(String.t() | nil) :: String.t()
  def worktree_branch(issue_identifier) do
    "symphony/#{safe_identifier(issue_identifier || "issue")}"
  end

  @spec repository_cache_key(map()) :: String.t()
  def repository_cache_key(project) do
    source = "#{Map.get(project, :repository_url) || "project"}:#{Map.get(project, :default_branch) || "main"}"
    digest = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    "#{project_slug(project)}-#{digest}"
  end

  @spec project_slug(map()) :: String.t()
  def project_slug(project) do
    project
    |> Map.get(:repository_url)
    |> case do
      url when is_binary(url) and url != "" -> Path.basename(url, ".git")
      _ -> "project"
    end
    |> safe_identifier()
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end
end
