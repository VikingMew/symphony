#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mise trust --yes mise.toml
mise install --yes
mise exec -- mix local.hex --force
mise exec -- mix local.rebar --force
mise exec -- mix setup
