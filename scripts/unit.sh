#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mix deps.get
HEX_OFFLINE=1 scripts/core_test.sh
mix test --cover
