#!/usr/bin/env bash
# Signal delivery and shutdown latency.
# Both long-lived services must observe SIGTERM, close their handles, drop a
# marker on the shared volume, and be gone in under two seconds.
. "$(dirname "$0")/_lib.sh"

BUDGET_SECONDS="${BUDGET_SECONDS:-2}"

wait_for_ready 60 || { fail "gateway is not ready, run 10-cold-boot.sh first"; finish; }

section "Clearing previous shutdown markers"
for svc in api-gateway image-processor; do
  rm -f "$SCRATCH_DIR_HOST/shutdown/$svc.json" 2>/dev/null \
    || docker exec "$(cid "$SVC_WORKER")" sh -c "rm -f /scratch/shutdown/$svc.json" 2>/dev/null \
    || warn "could not clear the marker for $svc"
done

for svc in "$SVC_GATEWAY" "$SVC_WORKER"; do
  section "Stopping $svc"
  c="$(cid "$svc")"
  [ -n "$c" ] || { fail "$svc container missing"; continue; }

  start_ns=$(date +%s%N 2>/dev/null || echo "")
  start_s=$(date +%s)
  # A generous grace period on purpose: if you need it, you already failed.
  docker stop --time 30 "$c" >/dev/null
  if [ -n "$start_ns" ]; then
    elapsed_ms=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  else
    elapsed_ms=$(( ( $(date +%s) - start_s ) * 1000 ))
  fi
  info "$svc stopped in ${elapsed_ms}ms"

  [ "$elapsed_ms" -lt $(( BUDGET_SECONDS * 1000 )) ]
  assert $? "$svc shut down in under ${BUDGET_SECONDS}s (took ${elapsed_ms}ms)"

  code="$(inspect "$c" '{{.State.ExitCode}}')"
  [ "$code" = "0" ]
  assert $? "$svc exited 0 rather than being killed (exit code $code)"

  if dc logs --tail 200 "$svc" 2>&1 | grep -q 'graceful shutdown complete'; then
    pass "$svc logged a completed graceful shutdown"
  else
    fail "$svc never logged a graceful shutdown - the signal did not reach the application"
    dc logs --tail 15 "$svc" 2>&1 | sed 's/^/          /'
  fi
done

section "Shutdown markers on the shared volume"
dc up -d >/dev/null 2>&1
wait_for_ready 90 || warn "stack did not come back ready after the restart"

for svc in api-gateway image-processor; do
  marker="$SCRATCH_DIR_HOST/shutdown/$svc.json"
  if [ -f "$marker" ]; then
    pass "$svc wrote a shutdown marker"
    info "$(tr -d '\n' < "$marker" | cut -c1-160)"
  elif docker exec "$(cid "$SVC_WORKER")" test -f "/scratch/shutdown/$svc.json" 2>/dev/null; then
    pass "$svc wrote a shutdown marker (read from inside the volume)"
  else
    fail "$svc left no shutdown marker - it was killed, not stopped"
  fi
done

section "Full-stack restart timing"
start_s=$(date +%s)
dc restart >/dev/null
info "docker compose restart took $(( $(date +%s) - start_s ))s"
[ $(( $(date +%s) - start_s )) -le $(( BUDGET_SECONDS * 4 )) ]
assert $? "the whole stack restarts without waiting out any kill timeout"

wait_for_ready 90; assert $? "stack is ready again after restart"

finish
