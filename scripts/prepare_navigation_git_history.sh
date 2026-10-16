#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
  git fetch --unshallow --no-tags origin
fi

git rev-parse --verify origin/main >/dev/null

if ! git rev-parse --verify --quiet refs/remotes/origin/HEAD >/dev/null; then
  git remote set-head origin -a >/dev/null
fi

git rev-parse --verify refs/remotes/origin/HEAD >/dev/null
