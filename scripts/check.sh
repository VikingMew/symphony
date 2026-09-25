#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mix deps.get
mix agent_code.check
mix format --check-formatted
mix lint
mix compile --warnings-as-errors
