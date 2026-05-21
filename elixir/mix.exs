defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 85
        ],
        ignore_modules: coverage_ignore_modules()
      ],
      test_ignore_filters: [
        "test/support/database_isolation.exs",
        "test/support/fake_persistence.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  @spec coverage_ignore_groups() :: [
          %{
            required(:category) => String.t(),
            required(:remove_when) => String.t(),
            required(:modules) => [module()]
          }
        ]
  def coverage_ignore_groups do
    [
      %{
        category: "protocol/process boundary",
        remove_when: "smaller injected boundaries make per-line coverage meaningful",
        modules: [
          SymphonyElixir.Config,
          SymphonyElixir.DatabaseSetup,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          Mix.Tasks.Symphony.Build
        ]
      },
      %{
        category: "storage boundary",
        remove_when: "context-level storage tests cover each schema/context public contract",
        modules: [
          SymphonyElixir.Persistence,
          SymphonyElixir.Persistence.AgentTurn,
          SymphonyElixir.Persistence.EventRecord,
          SymphonyElixir.Persistence.IssueRecord,
          SymphonyElixir.Persistence.Project,
          SymphonyElixir.Persistence.RunRecord,
          SymphonyElixir.Persistence.TaskLease,
          SymphonyElixir.Persistence.TaskRecord,
          SymphonyElixir.Persistence.TrackerConfig,
          SymphonyElixir.Persistence.User,
          SymphonyElixir.Persistence.Worker,
          SymphonyElixir.Persistence.WorkerSession,
          SymphonyElixir.Persistence.WorkflowVersion,
          SymphonyElixir.Persistence.WorkspaceRecord,
          SymphonyElixir.Repo
        ]
      },
      %{
        category: "presentation shell",
        remove_when: "LiveView/controller/component tests cover each module's own rendering contract",
        modules: [
          SymphonyElixir.StatusDashboard,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.AdminLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      }
    ]
  end

  defp coverage_ignore_modules do
    coverage_ignore_groups()
    |> Enum.flat_map(& &1.modules)
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.21"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["symphony.build"],
      lint: ["exec_plans.check", "specs.check", "credo --strict"]
    ]
  end
end
