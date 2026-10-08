#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/prepare_navigation_git_history.sh
mix deps.get
mix agent_code.check
mix observability.check
mix docs.check
mix format --check-formatted
mix lint
mix compile --warnings-as-errors
