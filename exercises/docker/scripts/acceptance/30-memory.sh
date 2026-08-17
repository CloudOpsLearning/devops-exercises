#!/usr/bin/env bash
# Memory pressure. The worker must survive SPIKE_MB of live heap inside whatever
# limit you gave it. Exit 137 (OOM kill) or a fatal heap abort is a failure.
. "$(dirname "$0")/_lib.sh"

SPIKES="${SPIKES:-6}"

wait_for_ready 60 || { fail "gateway is not ready, run 10-cold-boot.sh first"; finish; }

w="$(cid "$SVC_WORKER")"
[ -n "$w" ] || { fail "worker container missing"; finish; }

before_restarts="$(inspect "$w" '{{.RestartCount}}')"
limit_bytes="$(inspect "$w" '{{.HostConfig.Memory}}')"
info "worker memory limit: $(( ${limit_bytes:-0} / 1048576 ))MiB"
[ "${limit_bytes:-0}" -gt 0 ]
assert $? "the worker has an explicit memory limit (an unbounded worker is not a passing answer)"

section "Reported V8 heap ceiling"
runtime="$(curl -sS -m 10 "$GATEWAY_URL/debug/runtime")"
info "gateway execArgv: $(printf '%s' "$runtime" | grep -o '"execArgv":\[[^]]*\]')"

section "Driving $SPIKES processing spikes"
for i in $(seq 1 "$SPIKES"); do
  code="$(status_of POST /ingest/spike "{\"assetId\":\"spike-$i\"}")"
  [ "$code" = "202" ] || warn "spike $i enqueue returned $code"
done

section "Waiting for the spikes to settle"
deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  body="$(curl -sS -m 10 "$GATEWAY_URL/queue/stats" 2>/dev/null)"
  waiting="$(printf '%s' "$body" | grep -o '"waiting":[0-9]*' | grep -o '[0-9]*')"
  active="$(printf '%s' "$body" | grep -o '"active":[0-9]*' | grep -o '[0-9]*')"
  [ "${waiting:-1}" -eq 0 ] && [ "${active:-1}" -eq 0 ] && break
  sleep 3
done

section "Verdict"
w="$(cid "$SVC_WORKER")"
after_restarts="$(inspect "$w" '{{.RestartCount}}')"
exit_code="$(inspect "$w" '{{.State.ExitCode}}')"
oom="$(inspect "$w" '{{.State.OOMKilled}}')"

[ "$after_restarts" = "$before_restarts" ]
assert $? "worker did not restart during the spike storm (before=$before_restarts after=$after_restarts)"

[ "$oom" != "true" ]
assert $? "worker was never OOM killed by the kernel"

# Capture before grepping: `grep -q` closes the pipe early, and under pipefail that turns
# a successful match into a failed pipeline.
worker_logs="$(dc logs --tail 400 "$SVC_WORKER" 2>&1)"
if printf '%s' "$worker_logs" | grep -qE 'JavaScript heap out of memory|FATAL ERROR: .*Allocation failed'; then
  fail "worker aborted with a V8 heap allocation failure"
  printf '%s' "$worker_logs" | grep -E 'heap out of memory|Allocation failed' | head -3 | sed 's/^/          /'
else
  pass "no V8 allocation failure in the worker logs"
fi

if [ "$exit_code" = "137" ]; then
  fail "worker exit code is 137 - the container hit its cgroup limit"
else
  pass "worker exit code is not 137 (got: $exit_code)"
fi

failed="$(curl -sS -m 10 "$GATEWAY_URL/queue/stats" | grep -o '"failed":[0-9]*' | grep -o '[0-9]*')"
[ "${failed:-99}" -eq 0 ]
assert $? "no spike job ended up in the failed set (failed=${failed:-unknown})"

spike_artifacts="$(curl -sS -m 10 "$GATEWAY_URL/assets" | grep -o '"kind": *"spike"' | wc -l | tr -d '[:space:]')"
[ "${spike_artifacts:-0}" -gt 0 ]
assert $? "spike artifacts were written to the shared volume (found: ${spike_artifacts:-0})"

finish
