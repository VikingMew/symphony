#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
  git fetch --unshallow --no-tags origin
fi

git rev-parse --verify origin/main >/dev/null
