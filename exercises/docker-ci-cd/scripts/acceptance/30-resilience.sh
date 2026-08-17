#!/usr/bin/env bash
# Memory sizing and shutdown behaviour: the two things that turn a working image into
# a 3am page.
. "$(dirname "$0")/_lib.sh"

wait_for_api 120 || { fail "the API is not up, run 20-runtime.sh first"; finish; }
api="$(cid "$SVC_API")"
[ -n "$api" ] || { fail "the API container is missing"; finish; }

section "The JVM heap and the container limit have to agree"
limit_bytes="$(inspect "$api" '{{.HostConfig.Memory}}')"
limit_mb=$(( ${limit_bytes:-0} / 1048576 ))
info "container memory limit: ${limit_mb}MiB"
[ "${limit_bytes:-0}" -gt 0 ]
assert $? "the API container declares an explicit memory limit"

runtime_json="$(body_of GET /api/v1/runtime)"
max_heap_mb="$(json_field "$runtime_json" maxHeapMb)"
info "JVM max heap: ${max_heap_mb:-?}MiB of ${limit_mb}MiB"
info "JVM arguments: $(printf '%s' "$runtime_json" | grep -o '"jvmArguments":\[[^]]*\]')"

if [ "${limit_mb:-0}" -gt 0 ] && [ "${max_heap_mb:-0}" -gt 0 ]; then
  ratio=$(( max_heap_mb * 100 / limit_mb ))
  info "the JVM is claiming ${ratio}% of the container limit as heap"
  [ "$ratio" -ge 50 ]
  assert $? "the heap ceiling is deliberately sized against the container limit, not left at the default 25%"
  [ "$ratio" -le 90 ]
  assert $? "the heap ceiling leaves room for metaspace, thread stacks and native memory (${ratio}%)"
fi

section "Month-end reconciliation must not kill the pod"
before_restarts="$(inspect "$api" '{{.RestartCount}}')"
report_status="$(status_of POST /api/v1/reports/monthly "{\"megabytes\":${REPORT_MB}}")"
info "POST /api/v1/reports/monthly with megabytes=${REPORT_MB} returned $report_status"
[ "$report_status" = "200" ]
assert $? "the ${REPORT_MB}MiB report completes instead of failing"

report_body="$(body_of POST /api/v1/reports/monthly "{\"megabytes\":${REPORT_MB}}")"
peak="$(json_field "$report_body" peakHeapUsedMb)"
info "peak heap used while building the report: ${peak:-?}MiB"

api="$(cid "$SVC_API")"
after_restarts="$(inspect "$api" '{{.RestartCount}}')"
oom="$(inspect "$api" '{{.State.OOMKilled}}')"
[ "$before_restarts" = "$after_restarts" ]
assert $? "the API did not restart while building the report (before=$before_restarts after=$after_restarts)"
[ "$oom" != "true" ]
assert $? "the kernel did not OOM-kill the container"
# Capture first: `grep -q` closes the pipe early, and under pipefail that turns a
# successful match into a failed pipeline.
# Matched precisely: "-XX:+ExitOnOutOfMemoryError" in a startup line is a flag, not a fault.
OOM_PATTERN='java\.lang\.OutOfMemoryError|OutOfMemoryError while serving|Terminating due to java\.lang\.OutOfMemoryError'
api_logs="$(dc logs --tail 400 "$SVC_API" 2>&1)"
if printf '%s' "$api_logs" | grep -qE "$OOM_PATTERN"; then
  fail "the JVM threw OutOfMemoryError - the heap ceiling is below what the workload needs"
  printf '%s' "$api_logs" | grep -E "$OOM_PATTERN" | head -2 | sed 's/^/          /'
else
  pass "no OutOfMemoryError in the API logs"
fi

section "A settlement run in flight must survive a deploy"
batch="drain-$(date +%s)"
run_body="{\"seconds\":4,\"batchId\":\"$batch\"}"
tmp="$(mktemp)"
( curl -s -m 60 -o "$tmp" -w '%{http_code}' -X POST -H 'content-type: application/json' \
    -d "$run_body" "$API_URL/api/v1/settlements/run" > "${tmp}.code" 2>/dev/null ) &
runner=$!
sleep 1.5

info "requesting a stop while the settlement run is still open"
stop_start=$(date +%s)
docker stop --time 30 "$api" >/dev/null
stop_seconds=$(( $(date +%s) - stop_start ))
wait "$runner" 2>/dev/null
inflight_code="$(cat "${tmp}.code" 2>/dev/null)"
info "the in-flight request returned: ${inflight_code:-none} after a ${stop_seconds}s stop"

[ "$inflight_code" = "200" ]
assert $? "the settlement run that was already accepted completed instead of being cut off"
[ "$stop_seconds" -le 12 ]
assert $? "the container stopped within 12s rather than waiting out a kill timeout (${stop_seconds}s)"

shutdown_logs="$(dc logs --tail 200 "$SVC_API" 2>&1)"
if printf '%s' "$shutdown_logs" | grep -q 'graceful shutdown complete'; then
  pass "the application logged a graceful shutdown"
else
  fail "no graceful shutdown in the logs - the JVM was killed rather than asked to stop"
  printf '%s' "$shutdown_logs" | tail -12 | sed 's/^/          /'
fi

exit_code="$(inspect "$api" '{{.State.ExitCode}}')"
info "exit code: $exit_code (0 or 143 are both consistent with a handled SIGTERM)"
[ "$exit_code" = "0" ] || [ "$exit_code" = "143" ]
assert $? "the process exited on its own terms (got $exit_code, 137 would mean it was killed)"

section "The write that was in flight is really in the ledger"
dc up -d >/dev/null 2>&1
wait_for_api 120 || warn "the API did not come back up"
count="$(json_field "$(body_of GET "/api/v1/batches/$batch/count")" balanceMinor)"
info "ledger entries for batch $batch: ${count:-0}"
[ "${count:-0}" = "1" ]
assert $? "the settlement that was accepted before the stop was committed exactly once"

rm -f "$tmp" "${tmp}.code"
finish
