#!/usr/bin/env bash
# Shared helpers for the Helios acceptance suite.
# Source this from every check script: . "$(dirname "$0")/_lib.sh"

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
SCRATCH_DIR_HOST="${SCRATCH_DIR_HOST:-$ROOT/shared-scratch}"

# Service names are part of the contract - the suite cannot grade what it cannot find.
SVC_GATEWAY="${SVC_GATEWAY:-gateway}"
SVC_WORKER="${SVC_WORKER:-worker}"
SVC_MIGRATOR="${SVC_MIGRATOR:-migrator}"
SVC_DB="${SVC_DB:-db}"
SVC_CACHE="${SVC_CACHE:-cache}"

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

assert() { # assert <condition-exit-code> <description>
  if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi
}

finish() {
  printf '\n%d checks, %d failures\n' "$CHECKS" "$FAILURES"
  [ "$FAILURES" -eq 0 ] || exit 1
  exit 0
}

COMPOSE_FILE=""
for candidate in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
  if [ -f "$candidate" ]; then COMPOSE_FILE="$candidate"; break; fi
done

if [ -z "$COMPOSE_FILE" ]; then
  printf '%sno compose file found in %s - the suite has nothing to grade%s\n' "$C_BAD" "$ROOT" "$C_OFF" >&2
  exit 2
fi

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

cid() { # cid <service> -> container id or empty. Includes exited containers on purpose:
        # a one-shot job has to stay inspectable after it finishes.
  dc ps -a -q "$1" 2>/dev/null | head -n1
}

inspect() { # inspect <container-id> <go-template>
  docker inspect --format "$2" "$1" 2>/dev/null
}

http() { # http <method> <path> [json-body] -> "<body>\n<status>"
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -m 10 -o /dev/stdout -w '\n%{http_code}' -X "$method" \
      -H 'content-type: application/json' -d "$body" "${GATEWAY_URL}${path}" 2>/dev/null
  else
    curl -s -m 10 -o /dev/stdout -w '\n%{http_code}' -X "$method" "${GATEWAY_URL}${path}" 2>/dev/null
  fi
}

status_of() { # status_of <method> <path> [body] -> http status only
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -m 10 -o /dev/null -w '%{http_code}' -X "$method" \
      -H 'content-type: application/json' -d "$body" "${GATEWAY_URL}${path}" 2>/dev/null
  else
    curl -s -m 10 -o /dev/null -w '%{http_code}' -X "$method" "${GATEWAY_URL}${path}" 2>/dev/null
  fi
}

wait_for_ready() { # wait_for_ready <seconds>
  local deadline=$(( $(date +%s) + ${1:-90} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(status_of GET /readyz)" = "200" ]; then return 0; fi
    sleep 1
  done
  return 1
}

health_of() { # health_of <service> -> healthy|unhealthy|starting|none
  local c
  c="$(cid "$1")"
  [ -n "$c" ] || { printf 'missing'; return 1; }
  inspect "$c" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
}

wait_for_health() { # wait_for_health <service> <seconds>; 0 healthy, 1 timeout, 2 no healthcheck
  local svc="$1" deadline=$(( $(date +%s) + ${2:-60} )) status
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(health_of "$svc")"
    case "$status" in
      healthy) return 0 ;;
      none) return 2 ;;
    esac
    sleep 2
  done
  return 1
}
