%{
  generated: [],
  code_extensions: [".conf", ".css", ".ex", ".exs", ".heex", ".js", ".py", ".sh", ".toml", ".yaml", ".yml"],
  code_basenames: [".dockerignore", ".env.example", ".gitignore", "Dockerfile", "Makefile", "symphony"],
  data_paths: [".github/media/elixir-screenshot.png", ".github/media/symphony-demo-poster.jpg", ".github/media/symphony-demo.mp4", "docs/negative-assertion-inventory.tsv", "mix.lock"],
  clause_exceptions: [
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/analytics.ex",
      lines: 61,
      identifier: "quality/6@83",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/codex/app_server.ex",
      lines: 62,
      identifier: "handle_incoming/6@615",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/codex/app_server.ex",
      lines: 74,
      identifier: "handle_turn_method/8@740",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/codex/app_server.ex",
      lines: 109,
      identifier: "run_turn/4@87",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/codex/dynamic_tool/sections/request_execution.ex",
      lines: 544,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/codex/dynamic_tool/sections/updates.ex",
      lines: 639,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/config/schema/sections/defaults.ex",
      lines: 320,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/config/schema/sections/defaults.ex",
      lines: 79,
      identifier: "default_profiles/0@85",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/config/schema/sections/parsing.ex",
      lines: 304,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/config/schema/sections/types.ex",
      lines: 599,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/completion.ex",
      lines: 330,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/control.ex",
      lines: 931,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/orchestrator/sections/control.ex",
      lines: 99,
      identifier: "handle_call/3@212",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/dispatch.ex",
      lines: 725,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/orchestrator/sections/dispatch.ex",
      lines: 80,
      identifier: "dispatch_issue_agent/7@122",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/lifecycle.ex",
      lines: 785,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/persistence.ex",
      lines: 388,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/reconciliation.ex",
      lines: 800,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/orchestrator/sections/runtime_status.ex",
      lines: 906,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/worker/assignment_manager/sections/api.ex",
      lines: 681,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/worker/assignment_manager/sections/api.ex",
      lines: 66,
      identifier: "handle_call/3@349",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/worker/assignment_manager/sections/assignment.ex",
      lines: 728,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/worker/executor.ex",
      lines: 64,
      identifier: "execute/3@20",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/worker/executor.ex",
      lines: 68,
      identifier: "run_codex/5@85",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/workspace/sections/hooks.ex",
      lines: 745,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/workspace/sections/hooks.ex",
      lines: 66,
      identifier: "run_hook/7@129",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "lib/symphony_elixir/workspace/sections/lifecycle.ex",
      lines: 726,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir/workspace/sections/lifecycle.ex",
      lines: 101,
      identifier: "prepare_worktree_source/4@309",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/events.ex",
      lines: 111,
      identifier: "render/1@11",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/run_detail.ex",
      lines: 107,
      identifier: "render/1@13",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/agents.ex",
      lines: 164,
      identifier: "render/1@14",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/import.ex",
      lines: 80,
      identifier: "render/1@15",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/projects.ex",
      lines: 118,
      identifier: "render/1@14",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/admin_live/settings/runtime.ex",
      lines: 82,
      identifier: "render/1@14",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/analytics_live.ex",
      lines: 150,
      identifier: "render/1@22",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/dashboard_live.ex",
      lines: 431,
      identifier: "render/1@118",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/linear_diagnostics_live.ex",
      lines: 259,
      identifier: "render/1@65",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "lib/symphony_elixir_web/live/workers_live.ex",
      lines: 92,
      identifier: "render/1@19",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "mix.exs",
      lines: 136,
      identifier: "coverage_ignore_groups/0@53",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "priv/repo/migrations/20260501000000_create_symphony_persistence.exs",
      lines: 132,
      identifier: "change/0@5",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "priv/repo/migrations/20260501001000_create_worker_control_plane.exs",
      lines: 72,
      identifier: "change/0@5",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/fake_persistence_sections/fake_persistence_1.exs",
      lines: 585,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/fake_persistence_sections/fake_persistence_2.exs",
      lines: 644,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/agent_runner_1.exs",
      lines: 560,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/agent_runner_2.exs",
      lines: 413,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/assignment_manager_1.exs",
      lines: 815,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/assignment_manager_2.exs",
      lines: 850,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/assignment_manager_3.exs",
      lines: 575,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/core_1.exs",
      lines: 848,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/core_2.exs",
      lines: 767,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/extensions_1.exs",
      lines: 784,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/extensions_2.exs",
      lines: 641,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_1.exs",
      lines: 808,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_2.exs",
      lines: 758,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_3.exs",
      lines: 596,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/locality_sections/orchestrator_status_4.exs",
      lines: 367,
      identifier: "__using__/1@6",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Replace the compile-time section with cohesive helper modules after behavior-locking extraction.",
      path: "test/support/test_support.exs",
      lines: 94,
      identifier: "__using__/1@122",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "test/support/test_support.exs",
      lines: 152,
      identifier: "workflow_content/1@322",
      due: ~D[2026-10-23]
    },
    %{
      owner: "Symphony maintainers",
      split: "Extract named helpers or view components at the existing control-flow boundaries.",
      path: "test/symphony_elixir/live_e2e_test.exs",
      lines: 82,
      identifier: "run_live_issue_flow!/1@410",
      due: ~D[2026-10-23]
    }
  ]
}
