defmodule SymphonyElixir.RunAdmissionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunAdmission
  alias SymphonyElixir.Workflow

  setup do
    previous = Application.get_env(:symphony_elixir, :execution_mode)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:symphony_elixir, :execution_mode),
        else: Application.put_env(:symphony_elixir, :execution_mode, previous)
    end)

    :ok
  end

  test "execution mode projects both deployment modes as decision strings" do
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)
    assert RunAdmission.execution_mode() == "centralized"

    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    assert RunAdmission.execution_mode() == "worker"
  end

  @tag :tmp_dir
  test "resolves panel-local issue source and limits from one workflow snapshot", %{tmp_dir: tmp_dir} do
    workflow = workflow(tmp_dir, source_strategy: "worktree")
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)

    assert {:ok, admission} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:panel_local}
             })

    assert %RunAdmission{
             execution_mode: "centralized",
             workspace_authority: {:panel_local},
             source: %{
               repository: "git@example.test:repo.git",
               default_branch: "trunk",
               implementation_branch: "vikingmew-sym-156",
               source_strategy: "worktree",
               checkout_depth: 7
             },
             limits: %{
               initialize_timeout_ms: 61_001,
               max_turns: 11,
               max_failure_retries: 4,
               retry_backoff_ms: 91_000,
               turn_timeout_ms: 121_000,
               read_timeout_ms: 7_000,
               stall_timeout_ms: 301_000
             }
           } = admission
  end

  @tag :tmp_dir
  test "resolves centralized SSH and operator decisions through the injected adapter", %{tmp_dir: tmp_dir} do
    workflow = workflow(tmp_dir)
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)
    owner = self()

    readiness = fn authority, settings ->
      send(owner, {:readiness, authority, settings.workspace.root})
      :ok
    end

    assert {:ok, admission} =
             RunAdmission.resolve(workflow, {:operator, %{kind: :nap}}, %{
               workspace_authority: {:centralized_ssh, "worker-a"},
               readiness: readiness
             })

    assert admission.workspace_authority == {:centralized_ssh, "worker-a"}
    assert admission.source.implementation_branch == nil
    assert_receive {:readiness, {:centralized_ssh, "worker-a"}, ^tmp_dir}
  end

  @tag :tmp_dir
  test "HTTP-worker decision uses fresh readiness without projecting a worker-local path", %{tmp_dir: tmp_dir} do
    workflow = workflow(tmp_dir, source_strategy: "worktree")
    Application.put_env(:symphony_elixir, :execution_mode, :worker)

    assert {:ok, admission} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:http_worker, "worker-1", "session-1"},
               readiness: :ready
             })

    assert admission.execution_mode == "worker"
    assert admission.source.source_strategy == "worktree"
    refute inspect(admission) =~ tmp_dir
  end

  @tag :tmp_dir
  test "cleanup authorities select only the active centralized surfaces", %{tmp_dir: tmp_dir} do
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)
    assert RunAdmission.cleanup_authorities(workflow(tmp_dir)) == [{:panel_local}]

    assert RunAdmission.cleanup_authorities(workflow(tmp_dir, ssh_hosts: ["ssh-a", "ssh-b"])) == [
             {:centralized_ssh, "ssh-a"},
             {:centralized_ssh, "ssh-b"}
           ]

    Application.put_env(:symphony_elixir, :execution_mode, :worker)
    assert RunAdmission.cleanup_authorities(workflow(tmp_dir, ssh_hosts: ["ssh-a"])) == []
  end

  @tag :tmp_dir
  test "panel readiness preserves readonly, low-space, unavailable-space, and recovery evidence", %{tmp_dir: tmp_dir} do
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)
    workflow = workflow(tmp_dir, min_free_bytes: 100)

    assert {:error, {:environment_unavailable, %{kind: :not_writable, surface: :panel_local, reason: :erofs}}} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:panel_local},
               preflight_opts: [write_probe_fun: fn ^tmp_dir -> {:error, :erofs} end]
             })

    assert {:error, {:environment_unavailable, %{kind: :low_disk_space, surface: :panel_local}}} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:panel_local},
               preflight_opts: [write_probe_fun: fn _path -> :ok end, free_bytes_fun: fn _path -> {:ok, 99} end]
             })

    assert {:error, {:environment_unavailable, %{kind: :disk_space_unavailable, surface: :panel_local}}} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:panel_local},
               preflight_opts: [
                 write_probe_fun: fn _path -> :ok end,
                 free_bytes_fun: fn _path -> {:error, :no_stat} end
               ]
             })

    assert {:ok, _admission} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:panel_local},
               preflight_opts: [write_probe_fun: fn _path -> :ok end, free_bytes_fun: fn _path -> {:ok, 100} end]
             })
  end

  @tag :tmp_dir
  test "missing but creatable panel root is admitted without creating it", %{tmp_dir: tmp_dir} do
    root = Path.join([tmp_dir, "missing", "workspace"])
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)

    assert {:ok, _admission} =
             RunAdmission.resolve(workflow(root), {:issue, issue()}, %{
               workspace_authority: {:panel_local}
             })

    refute File.exists?(root)
  end

  @tag :tmp_dir
  test "SSH and HTTP-worker rejection evidence recovers on a later resolve", %{tmp_dir: tmp_dir} do
    workflow = workflow(tmp_dir)
    Application.put_env(:symphony_elixir, :execution_mode, :centralized)

    assert {:error, {:environment_unavailable, %{kind: :not_creatable, surface: :centralized_ssh}}} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:centralized_ssh, "ssh-a"},
               readiness: fn _authority, _settings -> {:error, %{kind: :not_creatable, reason: :eacces}} end
             })

    assert {:ok, _admission} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:centralized_ssh, "ssh-a"},
               readiness: fn _authority, _settings -> :ok end
             })

    Application.put_env(:symphony_elixir, :execution_mode, :worker)

    assert {:error, {:environment_unavailable, %{kind: :low_disk_space, surface: :http_worker}}} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:http_worker, "worker-1", "session-1"},
               readiness: {:error, %{kind: :low_disk_space}}
             })

    assert {:ok, _admission} =
             RunAdmission.resolve(workflow, {:issue, issue()}, %{
               workspace_authority: {:http_worker, "worker-1", "session-1"},
               readiness: :ready
             })
  end

  defp workflow(root, opts \\ []) do
    {:ok, loaded} = Workflow.load_example_package()

    config =
      loaded.config
      |> put_in(["workspace", "root"], root)
      |> put_in(["workspace", "repository_base_root"], root)
      |> put_in(["workspace", "worktree_base_root"], root)
      |> put_in(["workspace", "initialize_timeout_ms"], 61_001)
      |> put_in(["workspace", "min_free_bytes"], Keyword.get(opts, :min_free_bytes, 0))
      |> put_in(["project", "repository_url"], "git@example.test:repo.git")
      |> put_in(["project", "default_branch"], "trunk")
      |> put_in(["project", "source_strategy"], Keyword.get(opts, :source_strategy, "clone"))
      |> put_in(["project", "checkout_depth"], 7)
      |> put_in(["agent", "max_turns"], 11)
      |> put_in(["agent", "max_failure_retries"], 4)
      |> put_in(["agent", "max_retry_backoff_ms"], 91_000)
      |> put_in(["codex", "turn_timeout_ms"], 121_000)
      |> put_in(["codex", "read_timeout_ms"], 7_000)
      |> put_in(["codex", "stall_timeout_ms"], 301_000)
      |> Map.update(
        "worker",
        %{"ssh_hosts" => Keyword.get(opts, :ssh_hosts, [])},
        &Map.put(&1, "ssh_hosts", Keyword.get(opts, :ssh_hosts, []))
      )

    %{loaded | config: config}
  end

  defp issue do
    %Issue{
      id: "issue-156",
      identifier: "SYM-156",
      title: "Run admission",
      description: "",
      state: "Ready",
      branch_name: "vikingmew-sym-156",
      labels: []
    }
  end
end
