#!/usr/bin/env bash
# Aggressive ingest load. Every job shells out to the legacy exif sidecar, so this
# is also the check that discovers what your PID 1 is doing with orphaned children.
#
#   REQUESTS=800 CONCURRENCY=32 ./scripts/acceptance/20-load.sh
. "$(dirname "$0")/_lib.sh"

REQUESTS="${REQUESTS:-600}"
CONCURRENCY="${CONCURRENCY:-24}"

wait_for_ready 60 || { fail "gateway is not ready, run 10-cold-boot.sh first"; finish; }

section "Firing $REQUESTS ingest requests at concurrency $CONCURRENCY"
tmp="$(mktemp)"
start=$(date +%s)
seq 1 "$REQUESTS" | xargs -P "$CONCURRENCY" -I{} \
  curl -sS -m 15 -o /dev/null -w '%{http_code}\n' \
    -X POST -H 'content-type: application/json' \
    -d '{"assetId":"load-{}","sourceBytes":48123,"contentType":"image/jpeg"}' \
    "$GATEWAY_URL/ingest" >>"$tmp" 2>/dev/null
elapsed=$(( $(date +%s) - start ))

accepted=$(grep -c '^202$' "$tmp" || true)
rejected=$(grep -cvE '^202$' "$tmp" || true)
info "accepted=$accepted rejected=$rejected elapsed=${elapsed}s"
[ "$rejected" -eq 0 ]; assert $? "every ingest request was accepted (rejected=$rejected)"
rm -f "$tmp"

section "Queue drains"
deadline=$(( $(date +%s) + 120 ))
drained=1
while [ "$(date +%s)" -lt "$deadline" ]; do
  body="$(curl -sS -m 10 "$GATEWAY_URL/queue/stats" 2>/dev/null)"
  waiting="$(printf '%s' "$body" | grep -o '"waiting":[0-9]*' | grep -o '[0-9]*')"
  active="$(printf '%s' "$body" | grep -o '"active":[0-9]*' | grep -o '[0-9]*')"
  if [ "${waiting:-1}" -eq 0 ] && [ "${active:-1}" -eq 0 ]; then drained=0; break; fi
  sleep 2
done
assert "$drained" "queue drained to zero waiting/active"

section "Nothing died under load"
for svc in "$SVC_GATEWAY" "$SVC_WORKER"; do
  c="$(cid "$svc")"
  [ -n "$c" ] || { fail "$svc container missing"; continue; }
  [ "$(inspect "$c" '{{.RestartCount}}')" = "0" ]
  assert $? "$svc restart count is still 0"
  [ "$(inspect "$c" '{{.State.Running}}')" = "true" ]
  assert $? "$svc is still running"
done

section "PID namespace hygiene"
w="$(cid "$SVC_WORKER")"
if [ -n "$w" ]; then
  # The sidecar's detached work outlives the wrapper that started it, so counting
  # too early counts running processes, not the mess they leave behind.
  linger="$(docker exec "$w" sh -c 'echo ${SIDECAR_LINGER_SECONDS:-12}' 2>/dev/null | tr -d '[:space:]')"
  case "$linger" in ''|*[!0-9]*) linger=12 ;; esac
  info "waiting $((linger + 3))s for the sidecar's detached work to exit"
  sleep $((linger + 3))

  zombies="$(docker exec "$w" sh -c 'ps -eo stat= 2>/dev/null | grep -c "^Z"' 2>/dev/null | tr -d '[:space:]')"
  case "$zombies" in
    ''|*[!0-9]*)
      zombies="$(docker exec "$w" sh -c 'for p in /proc/[0-9]*; do sed -n "s/.*) \([A-Z]\).*/\1/p" "$p/stat" 2>/dev/null; done | grep -c Z' 2>/dev/null | tr -d '[:space:]')"
      ;;
  esac
  info "zombie processes inside the worker: ${zombies:-unknown}"
  [ "${zombies:-999}" -le 5 ]
  assert $? "worker pid namespace is not filling with unreaped children (zombies=${zombies:-unknown})"

  pid1="$(docker exec "$w" sh -c 'cat /proc/1/comm' 2>/dev/null | tr -d '[:space:]')"
  info "pid 1 inside the worker is: ${pid1:-unknown}"

  # A container needs `retries` consecutive failures before it latches unhealthy,
  # so this is a coarse signal - the zombie count above is the precise one.
  hs="$(health_of "$SVC_WORKER")"
  [ "$hs" != "unhealthy" ] && [ "$hs" != "missing" ] && [ "$hs" != "none" ]
  assert $? "worker is not reporting unhealthy after load (status: $hs)"
fi

section "Work actually landed"
processed="$(curl -sS -m 10 "$GATEWAY_URL/assets" | grep -o '"file":' | wc -l | tr -d '[:space:]')"
[ "${processed:-0}" -gt 0 ]
assert $? "the gateway can read artifacts the worker wrote (visible files: ${processed:-0})"

finish
