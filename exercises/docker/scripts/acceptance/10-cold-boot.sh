#!/usr/bin/env bash
# Cold boot from nothing. This is the check that catches the migration race:
# a stack that only works on the second `up` has not been solved.
. "$(dirname "$0")/_lib.sh"

section "Destroying any previous state"
dc down --volumes --remove-orphans >/dev/null 2>&1
rm -rf "${SCRATCH_DIR_HOST:?}/processed" "${SCRATCH_DIR_HOST:?}/shutdown" 2>/dev/null \
  || warn "could not clean shared-scratch as this user - that is itself a finding (see 50-ownership.sh)"

section "Cold boot"
start=$(date +%s)
if dc up -d --build; then
  pass "docker compose up -d --build returned 0"
else
  fail "docker compose up -d --build failed"
  finish
fi

if wait_for_ready 120; then
  pass "gateway reported ready in $(( $(date +%s) - start ))s"
else
  fail "gateway never became ready within 120s"
  info "last 40 lines of gateway logs:"
  dc logs --tail 40 "$SVC_GATEWAY" | sed 's/^/          /'
fi

section "Migrator ran to completion exactly once"
mig="$(cid "$SVC_MIGRATOR")"
if [ -z "$mig" ]; then
  fail "migrator container not found (it must remain inspectable after exiting)"
else
  state="$(inspect "$mig" '{{.State.Status}}')"
  code="$(inspect "$mig" '{{.State.ExitCode}}')"
  restarts="$(inspect "$mig" '{{.RestartCount}}')"
  [ "$state" = "exited" ] && [ "$code" = "0" ]
  assert $? "migrator exited 0 (state=$state code=$code)"
  [ "${restarts:-0}" -le 1 ]
  assert $? "migrator did not thrash (restarts=$restarts)"
fi

section "No consumer crashed while waiting for the schema"
for svc in "$SVC_GATEWAY" "$SVC_WORKER"; do
  c="$(cid "$svc")"
  if [ -z "$c" ]; then
    fail "$svc container not found"
    continue
  fi
  restarts="$(inspect "$c" '{{.RestartCount}}')"
  [ "${restarts:-99}" -eq 0 ]
  assert $? "$svc never restarted during cold boot (restarts=$restarts)"

  # Capture before grepping: `grep -q` closes the pipe early, and under pipefail that
  # turns a successful match into a failed pipeline.
  svc_logs="$(dc logs "$svc" 2>&1)"
  if printf '%s' "$svc_logs" | grep -qE 'UnhandledPromiseRejection|SchemaNotReadyError|platform_meta.*does not exist'; then
    fail "$svc logged a schema-race crash"
    printf '%s' "$svc_logs" | grep -E 'UnhandledPromiseRejection|SchemaNotReadyError|does not exist' | head -3 | sed 's/^/          /'
  else
    pass "$svc logged no schema-race crash"
  fi
done

section "Health endpoints behave differently"
[ "$(status_of GET /healthz)" = "200" ]; assert $? "GET /healthz is 200"
[ "$(status_of GET /readyz)" = "200" ]; assert $? "GET /readyz is 200"

section "Worker health probe"
wait_for_health "$SVC_WORKER" 60
case $? in
  0) pass "worker container healthcheck reports healthy" ;;
  2) fail "worker container declares no healthcheck" ;;
  *) fail "worker container never became healthy (last status: $(health_of "$SVC_WORKER"))"
     dc logs --tail 20 "$SVC_WORKER" | sed 's/^/          /' ;;
esac

finish
