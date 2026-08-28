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
        ignore_warnings: ".dialyzer_ignore.exs",
        plt_add_apps: [:mix]
      ],
      releases: [
        symphony: [
          applications: [runtime_tools: :permanent]
        ]
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
            required(:exit_slices) => %{required(module()) => String.t()},
            required(:modules) => [module()]
          }
        ]
  def coverage_ignore_groups do
    [
      %{
        category: "protocol/process boundary",
        remove_when: "smaller injected boundaries make per-line coverage meaningful",
        exit_slices: %{
          SymphonyElixir.Config => "split runtime settings loading from process/env access, then count the pure loader",
          SymphonyElixir.DatabaseSetup => "move migration/bootstrap orchestration behind a command boundary and keep schema checks covered elsewhere",
          SymphonyElixir.Release => "cover release maintenance entrypoints through the explicit PostgreSQL smoke target",
          SymphonyElixir.SQLiteImporter => "cover the one-way legacy import boundary through the explicit PostgreSQL smoke target",
          SymphonyElixir.Linear.Client => "extract GraphQL query construction and response decoding into counted pure modules",
          SymphonyElixir.SpecsCheck => "extract spec file parsing and validation into a counted module",
          SymphonyElixir.Persistence.WorkflowStore => "extract active-version loading and poll decision logic behind a mockable workflow-store adapter before counting the GenServer shell",
          SymphonyElixir.Orchestrator => "continue moving retry, run lifecycle, and state-machine policies into counted helpers",
          SymphonyElixir.Orchestrator.State => "cover through extracted state transition helpers before counting the process shell",
          SymphonyElixir.AgentRunner => "extract agent exit classification and workspace/codex sequencing into counted helpers",
          SymphonyElixir.CLI => "cover option parsing separately from booting the supervision tree",
          SymphonyElixir.Codex.AppServer => "extract startup command building, sandbox normalization, and response classification",
          SymphonyElixir.HttpServer => "extract config resolution and endpoint host/port parsing",
          SymphonyElixir.LogFile => "extract file path and formatter behavior from logger side effects",
          SymphonyElixir.Workspace => "extract source strategy, cleanup policy, and hook command behavior before counting the process boundary",
          SymphonyElixir.Worker.Application => "cover the worker-only supervision tree in the release image smoke",
          SymphonyElixir.Worker.Client => "cover transport failures with an injected HTTP adapter before counting the Req shell",
          SymphonyElixir.Worker.Command => "cover process-group signals on an executable integration filesystem before counting the port shell",
          SymphonyElixir.Worker.Config => "cover production runtime loading through the worker image smoke",
          SymphonyElixir.Worker.Executor => "cover orchestration branches through injected phase boundaries before counting the lease shell",
          SymphonyElixir.Worker.Runtime => "cover timer and recovery behavior through an injected client before counting the GenServer shell",
          Mix.Tasks.Symphony.Build => "keep as a Mix shell until release build packaging has a deterministic fake",
          Mix.Tasks.Symphony.Migrate => "cover the command wrapper through the release migration smoke",
          Mix.Tasks.Symphony.PostgresSmoke => "run this integration harness against PostgreSQL instead of counting it in unit coverage",
          Mix.Tasks.Symphony.SqliteImport => "cover the command wrapper through the SQLite cutover smoke"
        },
        modules: [
          SymphonyElixir.Config,
          SymphonyElixir.DatabaseSetup,
          SymphonyElixir.Release,
          SymphonyElixir.SQLiteImporter,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Persistence.WorkflowStore,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.HttpServer,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          SymphonyElixir.Worker.Application,
          SymphonyElixir.Worker.Client,
          SymphonyElixir.Worker.Command,
          SymphonyElixir.Worker.Config,
          SymphonyElixir.Worker.Executor,
          SymphonyElixir.Worker.Runtime,
          Mix.Tasks.Symphony.Build,
          Mix.Tasks.Symphony.Migrate,
          Mix.Tasks.Symphony.PostgresSmoke,
          Mix.Tasks.Symphony.SqliteImport
        ]
      },
      %{
        category: "storage boundary",
        remove_when: "context-level storage tests cover each schema/context public contract",
        exit_slices: %{
          SymphonyElixir.Persistence => "count after repository functions are tested through adapter contracts instead of real DB setup",
          SymphonyElixir.Persistence.WorkerQueue =>
            "extract queue command normalization and lease transition decisions behind a fake repository contract before counting Repo-bound queue orchestration",
          SymphonyElixir.Persistence.AgentTurn => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.EventRecord => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.IssueRecord => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.Project => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.TaskLease => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.TrackerConfig => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.User => "count with password/hash schema tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.WorkerSession => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Persistence.WorkflowRecord => "count with schema changeset tests when persistence schemas leave the blanket group",
          SymphonyElixir.Repo => "permanent framework adapter shell unless a DB integration target is reintroduced"
        },
        modules: [
          SymphonyElixir.Persistence,
          SymphonyElixir.Persistence.WorkerQueue,
          SymphonyElixir.Persistence.AgentTurn,
          SymphonyElixir.Persistence.EventRecord,
          SymphonyElixir.Persistence.IssueRecord,
          SymphonyElixir.Persistence.Project,
          SymphonyElixir.Persistence.TaskLease,
          SymphonyElixir.Persistence.TrackerConfig,
          SymphonyElixir.Persistence.User,
          SymphonyElixir.Persistence.WorkerSession,
          SymphonyElixir.Persistence.WorkflowRecord,
          SymphonyElixir.Repo
        ]
      },
      %{
        category: "presentation shell",
        remove_when: "LiveView/controller/component tests cover each module's own rendering contract",
        exit_slices: %{
          SymphonyElixir.StatusDashboard => "extract snapshot formatting and display policy into counted helpers before counting the process loop",
          SymphonyElixirWeb.DashboardLive => "count when dashboard rendering is split from live process callbacks",
          SymphonyElixirWeb.AdminLive => "count as settings/domain helpers are extracted from the large LiveView",
          SymphonyElixirWeb.WorkersLive => "count after worker table rendering and action policy are extracted from LiveView process callbacks",
          SymphonyElixirWeb.Endpoint => "permanent Phoenix endpoint shell",
          SymphonyElixirWeb.ErrorHTML => "count after focused error rendering assertions are added",
          SymphonyElixirWeb.ErrorJSON => "count after focused JSON error rendering assertions are added",
          SymphonyElixirWeb.Layouts => "count after layout rendering assertions are added",
          SymphonyElixirWeb.ObservabilityApiController => "count after controller response tests cover each branch",
          SymphonyElixirWeb.StaticAssetController => "count after static asset response tests cover cache and not-found branches",
          SymphonyElixirWeb.StaticAssets => "count after asset lookup helpers are isolated",
          SymphonyElixirWeb.Router => "permanent Phoenix router shell unless route helpers become hand-written logic",
          SymphonyElixirWeb.Router.Helpers => "permanent Phoenix helper shell"
        },
        modules: [
          SymphonyElixir.StatusDashboard,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.AdminLive,
          SymphonyElixirWeb.WorkersLive,
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
      {:postgrex, "~> 0.21"},
      {:castore, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["symphony.build"],
      lint: ["specs.check", "credo --strict"],
      "symphony.pg_smoke": ["symphony.postgres_smoke"]
    ]
  end
end
