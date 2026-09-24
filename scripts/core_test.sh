#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mix test \
  test/symphony_elixir/api_governance_test.exs \
  test/symphony_elixir/dependency_boundary_governance_test.exs \
  test/symphony_elixir/default_test_boundary_test.exs \
  test/symphony_elixir/mixed_key_access_governance_test.exs \
  test/symphony_elixir/path_safety_test.exs \
  test/symphony_elixir/payload_test.exs \
  test/symphony_elixir/prompt_builder_test.exs
