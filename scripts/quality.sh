#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/check.sh
scripts/unit.sh
scripts/dialyzer.sh
