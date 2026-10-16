#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-$ROOT_DIR/.env}
COMPOSE_FILES=(-f "$ROOT_DIR/compose.yaml" -f "$ROOT_DIR/compose.worker-release.yaml" -f "$ROOT_DIR/compose.host-override.yaml")
COMPOSE_PROFILE=(--profile execution-worker)
STAGE=preflight
TARGET_SHA=
PANEL_IMAGE=
WORKER_IMAGE=
PANEL_URL=
BACKUP_FILE=
REPORTING=0

load_env() {
  local explicit_panel_url=${SYMPHONY_PANEL_URL-}
  [[ -f "$ENV_FILE" ]] || { echo "missing env file: $ENV_FILE" >&2; return 1; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  if [[ -n "$explicit_panel_url" ]]; then
    SYMPHONY_PANEL_URL=$explicit_panel_url
  fi
  PANEL_URL=${SYMPHONY_PANEL_URL:-http://127.0.0.1:${SYMPHONY_DASHBOARD_PORT:-4000}}
}

usage() {
  echo "usage: scripts/deploy.sh <deploy|check> <40-character lowercase commit sha>" >&2
  exit 2
}

pin_value() {
  local key=$1
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found=1; exit } END { if (!found) exit 1 }' "$ENV_FILE"
}

actual_image() {
  local service=$1 container image
  container=$(docker compose "${COMPOSE_FILES[@]}" "${COMPOSE_PROFILE[@]}" ps -q "$service" 2>/dev/null || true)
  [[ -n "$container" ]] || { echo "<unavailable>"; return 0; }
  image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
  echo "${image:-<unavailable>}"
}

report_state() {
  ((REPORTING)) && return 0
  REPORTING=1
  echo "deployment failed" >&2
  echo "stage: $STAGE" >&2
  echo "target sha: ${TARGET_SHA:-unknown}" >&2
  for key in SYMPHONY_IMAGE SYMPHONY_EXECUTION_WORKER_IMAGE SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION; do
    echo "$key: $(pin_value "$key" 2>/dev/null || echo '<unset>')" >&2
  done
  echo "Panel actual image: $(actual_image symphony)" >&2
  echo "worker actual image: $(actual_image execution-worker)" >&2
}

on_exit() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    report_state || true
  fi
  exit "$status"
}
trap on_exit EXIT

compose() {
  docker compose "${COMPOSE_FILES[@]}" "${COMPOSE_PROFILE[@]}" --env-file "$ENV_FILE" "$@"
}

validate_target() {
  [[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "target must be a 40-character lowercase commit SHA" >&2; return 1; }
  PANEL_IMAGE=${SYMPHONY_IMAGE_REPOSITORY:-ghcr.io/vikingmew/symphony}:sha-$TARGET_SHA
  WORKER_IMAGE=${SYMPHONY_EXECUTION_WORKER_IMAGE_REPOSITORY:-ghcr.io/vikingmew/symphony-execution-worker}:sha-$TARGET_SHA
  export SYMPHONY_IMAGE="$PANEL_IMAGE"
  export SYMPHONY_EXECUTION_WORKER_IMAGE="$WORKER_IMAGE"
  export SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION="$TARGET_SHA"
}

backup_postgres() {
  local backup_dir=${SYMPHONY_BACKUP_DIR:-${TMPDIR:-/tmp}/symphony-backups}
  mkdir -p "$backup_dir"
  BACKUP_FILE="$backup_dir/symphony-${TARGET_SHA}-$(date -u +%Y%m%dT%H%M%SZ).dump"
  compose exec -T postgres pg_dump --format=custom --no-owner --no-acl -U "${POSTGRES_USER:-symphony}" "${POSTGRES_DB:-symphony}" >"$BACKUP_FILE"
}

update_pins() {
  local tmp
  tmp=$(mktemp "${ENV_FILE}.tmp.XXXXXX")
  awk -v panel="$PANEL_IMAGE" -v worker="$WORKER_IMAGE" -v sha="$TARGET_SHA" '
    BEGIN { panel_done=worker_done=source_done=0 }
    /^SYMPHONY_IMAGE=/ { print "SYMPHONY_IMAGE=" panel; panel_done=1; next }
    /^SYMPHONY_EXECUTION_WORKER_IMAGE=/ { print "SYMPHONY_EXECUTION_WORKER_IMAGE=" worker; worker_done=1; next }
    /^SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=/ { print "SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=" sha; source_done=1; next }
    { print }
    END {
      if (!panel_done) print "SYMPHONY_IMAGE=" panel
      if (!worker_done) print "SYMPHONY_EXECUTION_WORKER_IMAGE=" worker
      if (!source_done) print "SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION=" sha
    }
  ' "$ENV_FILE" >"$tmp"
  chmod --reference="$ENV_FILE" "$tmp" 2>/dev/null || true
  mv "$tmp" "$ENV_FILE"
}

check_deployment() {
  STAGE=check
  local panel_pin worker_pin source_pin panel_actual worker_actual ready workers ok=0
  panel_pin=$(pin_value SYMPHONY_IMAGE)
  worker_pin=$(pin_value SYMPHONY_EXECUTION_WORKER_IMAGE)
  source_pin=$(pin_value SYMPHONY_EXECUTION_WORKER_SOURCE_REVISION)
  panel_actual=$(actual_image symphony)
  worker_actual=$(actual_image execution-worker)
  ready=$(curl --fail --silent "$PANEL_URL/health/ready")
  workers=$(curl --fail --silent "$PANEL_URL/workers")

  if [[ "$panel_pin" == "$PANEL_IMAGE" && "$worker_pin" == "$WORKER_IMAGE" && "$source_pin" == "$TARGET_SHA" && "$panel_actual" == "$PANEL_IMAGE" && "$worker_actual" == "$WORKER_IMAGE" ]]; then
    echo "images: same sha"
  else
    echo "images: drift (target panel=$PANEL_IMAGE worker=$WORKER_IMAGE; actual panel=$panel_actual worker=$worker_actual)" >&2
    ok=1
  fi
  if jq -e '.checks.migrations == "current"' >/dev/null <<<"$ready"; then
    echo "migrations: current"
  else
    echo "migrations: drift" >&2
    ok=1
  fi
  if grep -Eiq '(^|[^[:alpha:]])online([^[:alpha:]]|$)' <<<"$workers"; then
    echo "worker session: online"
  else
    echo "worker session: drift" >&2
    ok=1
  fi
  if [[ "$panel_pin" == "$PANEL_IMAGE" && "$worker_pin" == "$WORKER_IMAGE" && "$source_pin" == "$TARGET_SHA" ]]; then
    echo "pins: current"
  else
    echo "pins: drift (panel=$panel_pin worker=$worker_pin source=$source_pin)" >&2
    ok=1
  fi
  return "$ok"
}

main() {
  local action=${1-} sha=${2-}
  [[ $# -eq 2 ]] || usage
  case "$action" in deploy|check) ;; *) usage ;; esac
  TARGET_SHA=$sha
  load_env
  validate_target

  if [[ "$action" == check ]]; then
    check_deployment
    return
  fi

  STAGE=pull
  compose pull symphony execution-worker
  STAGE=backup
  backup_postgres
  STAGE=pins
  update_pins
  STAGE=migration
  compose run --rm --no-build migrate
  STAGE=switch
  compose up -d --no-build symphony execution-worker
  check_deployment
  echo "deployment verified; next step: manually enable listening"
}

main "$@"
