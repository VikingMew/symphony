#!/usr/bin/env bash
set -euo pipefail

panel_url=${1:-${SYMPHONY_PANEL_URL:-http://127.0.0.1:4000}}
cookie_args=()

if [[ -n "${SYMPHONY_PANEL_COOKIE_FILE:-}" ]]; then
  cookie_args=(--cookie "${SYMPHONY_PANEL_COOKIE_FILE}")
fi

response=$(
  curl --fail --silent --show-error \
    --request POST \
    --header 'content-type: application/json' \
    "${cookie_args[@]}" \
    --data '{"mode":"off"}' \
    "${panel_url%/}/api/v1/control/listening"
)

if [[ "$response" =~ \"listening\"[[:space:]]*:[[:space:]]*false ]] &&
   [[ "$response" =~ \"mode\"[[:space:]]*:[[:space:]]*\"off\" ]]; then
  echo "not_listening"
else
  echo "unexpected listening response: $response" >&2
  exit 1
fi
