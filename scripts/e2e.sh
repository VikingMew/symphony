#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mix deps.get
SYMPHONY_RUN_LIVE_E2E=1 mix test --only live_e2e
