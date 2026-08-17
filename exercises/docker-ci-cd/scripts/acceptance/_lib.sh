#!/usr/bin/env bash
# Shared helpers for the Kestrel settlement acceptance suite.
# Source from every stage: . "$(dirname "$0")/_lib.sh"

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

# ---- the contract the suite grades against -------------------------------
API_URL="${API_URL:-http://localhost:8080}"
IMAGE="${IMAGE:-kestrel/settlement-api:exam}"
IMAGE_MAX_MB="${IMAGE_MAX_MB:-450}"
REPORT_MB="${REPORT_MB:-192}"
BUILD_VERSION="${BUILD_VERSION:-1.4.2-exam}"

SVC_API="${SVC_API:-api}"
SVC_DB="${SVC_DB:-db}"
SVC_MIGRATOR="${SVC_MIGRATOR:-migrator}"

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_OFF=""
fi

FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '%s  PASS%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '%s  FAIL%s  %s\n' "$C_BAD" "$C_OFF" "$1"; }
warn() { printf '%s  WARN%s  %s\n' "$C_WARN" "$C_OFF" "$1"; }
info() { printf '%s        %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
section() { printf '\n== %s ==\n' "$1"; }

assert() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi }

finish() {
  printf '\n%d checks, %d failures\n' "$CHECKS" "$FAILURES"
  [ "$FAILURES" -eq 0 ] || exit 1
  exit 0
}

# ---- git -----------------------------------------------------------------
git_revision() {
  git rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000"
}

# ---- compose -------------------------------------------------------------
COMPOSE_FILE=""
for candidate in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
  if [ -f "$candidate" ]; then COMPOSE_FILE="$candidate"; break; fi
done

dc() {
  if [ -z "$COMPOSE_FILE" ]; then return 2; fi
  docker compose -f "$COMPOSE_FILE" "$@"
}

cid() { dc ps -a -q "$1" 2>/dev/null | head -n1; }

inspect() { docker inspect --format "$2" "$1" 2>/dev/null; }

# ---- pipeline definition -------------------------------------------------
pipeline_files() {
  local found=""
  if [ -d .github/workflows ]; then
    found="$(find .github/workflows -maxdepth 1 -name '*.yml' -o -maxdepth 1 -name '*.yaml' 2>/dev/null)"
  fi
  for extra in .gitlab-ci.yml .gitlab-ci.yaml Jenkinsfile; do
    [ -f "$extra" ] && found="$found $extra"
  done
  printf '%s' "$found"
}

pipeline_text() {
  local files
  files="$(pipeline_files)"
  [ -n "$files" ] || return 1
  # shellcheck disable=SC2086
  cat $files 2>/dev/null
}

# ---- http ----------------------------------------------------------------
status_of() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -m 30 -o /dev/null -w '%{http_code}' -X "$method" \
      -H 'content-type: application/json' -d "$body" "${API_URL}${path}" 2>/dev/null
  else
    curl -s -m 30 -o /dev/null -w '%{http_code}' -X "$method" "${API_URL}${path}" 2>/dev/null
  fi
}

body_of() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -m 60 -X "$method" -H 'content-type: application/json' -d "$body" "${API_URL}${path}" 2>/dev/null
  else
    curl -s -m 60 -X "$method" "${API_URL}${path}" 2>/dev/null
  fi
}

json_field() { # json_field <json> <field> -> first scalar value
  printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[-0-9.]*\|true\|false\)" \
    | head -n1 | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//'
}

wait_for_api() { # wait_for_api <seconds>
  local deadline=$(( $(date +%s) + ${1:-120} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(status_of GET /api/v1/runtime)" = "200" ]; then return 0; fi
    sleep 2
  done
  return 1
}

# ---- in-network probing --------------------------------------------------
# The management port must never be published, and the application image is not
# required to contain a shell or curl. So the suite asks from a throwaway container
# attached to the same network instead of from inside the application container.
CURL_SIDECAR_IMAGE="${CURL_SIDECAR_IMAGE:-curlimages/curl:8.10.1}"
MANAGEMENT_PORT="${MANAGEMENT_PORT:-9090}"

api_network() {
  local c
  c="$(cid "$SVC_API")"
  [ -n "$c" ] || return 1
  inspect "$c" '{{range $name, $conf := .NetworkSettings.Networks}}{{$name}} {{end}}' | awk '{print $1}'
}

in_network_get() { # in_network_get <url> -> body on stdout, curl exit status
  local net
  net="$(api_network)"
  [ -n "$net" ] || return 1
  docker run --rm --network "$net" "$CURL_SIDECAR_IMAGE" -sS -m 10 "$1" 2>/dev/null
}

in_network_status() { # in_network_status <url> -> http status
  local net
  net="$(api_network)"
  [ -n "$net" ] || { printf '000'; return 1; }
  docker run --rm --network "$net" "$CURL_SIDECAR_IMAGE" \
    -s -m 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null
}

probe_readiness() {
  in_network_get "http://${SVC_API}:${MANAGEMENT_PORT}/actuator/health/readiness"
}

# Which OS user the container's processes actually run as, without needing tools
# inside the image.
container_process_user() {
  docker top "$1" 2>/dev/null | awk 'NR==2 {print $1}'
}

wait_for_readiness() { # wait_for_readiness <seconds>
  local deadline=$(( $(date +%s) + ${1:-120} )) out
  while [ "$(date +%s)" -lt "$deadline" ]; do
    out="$(probe_readiness)"
    case "$out" in *'"status":"UP"'*) printf '%s' "$out"; return 0 ;; esac
    sleep 2
  done
  printf '%s' "${out:-}"
  return 1
}
