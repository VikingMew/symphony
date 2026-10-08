#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/prepare_navigation_git_history.sh
unset SYMPHONY_RUN_LIVE_E2E
export HEX_OFFLINE=1
scripts/core_test.sh
mix test --cover
