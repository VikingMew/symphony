#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mix deps.get
mix test --cover
