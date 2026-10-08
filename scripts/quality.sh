#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec mise exec -- elixir scripts/quality.exs
