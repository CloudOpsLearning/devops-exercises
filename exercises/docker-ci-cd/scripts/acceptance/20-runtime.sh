#!/usr/bin/env bash
# Brings the stack up from nothing and grades the running system.
. "$(dirname "$0")/_lib.sh"

REVISION="$(git_revision)"

section "Cold start from an empty database"
dc down --volumes --remove-orphans >/dev/null 2>&1
start=$(date +%s)
if dc up -d --build; then
  pass "docker compose up -d --build returned 0"
else
  fail "docker compose up -d --build failed"
  finish
fi

if wait_for_api 180; then
  pass "the API answered on $API_URL after $(( $(date +%s) - start ))s"
else
  fail "the API never answered within 180s"
  dc logs --tail 40 "$SVC_API" | sed 's/^/          /'
  finish
fi

section "The schema is applied by a job, not by the application"
mig="$(cid "$SVC_MIGRATOR")"
if [ -z "$mig" ]; then
  fail "the migrator container is missing (it must stay inspectable after it exits)"
else
  state="$(inspect "$mig" '{{.State.Status}}')"
  code="$(inspect "$mig" '{{.State.ExitCode}}')"
  [ "$state" = "exited" ] && [ "$code" = "0" ]
  assert $? "the migration job ran to completion (state=$state exit=$code)"

  api_image="$(inspect "$(cid "$SVC_API")" '{{.Config.Image}}')"
  mig_image="$(inspect "$mig" '{{.Config.Image}}')"
  info "api image: $api_image"
  info "migrator image: $mig_image"
  [ "$api_image" = "$mig_image" ]
  assert $? "the migration job runs the same image as the API"

  # Capture before grepping: `grep -q` exits early, and under pipefail that would turn a
  # successful match into a failed pipeline.
  migrator_logs="$(dc logs "$SVC_MIGRATOR" 2>&1)"
  printf '%s' "$migrator_logs" | grep -q 'schema is up to date'
  assert $? "the migration job reported the schema is up to date"
fi

api="$(cid "$SVC_API")"
restarts="$(inspect "$api" '{{.RestartCount}}')"
[ "${restarts:-99}" -eq 0 ]
assert $? "the API did not restart on the way up (restarts=$restarts)"

section "Readiness means more than 'the process started'"
readiness="$(wait_for_readiness 120)"
if printf '%s' "$readiness" | grep -q '"status":"UP"'; then
  pass "readiness is UP on the management port"
  applied="$(json_field "$readiness" appliedVersion)"
  info "schema contract: applied=${applied:-?}"
  [ "${applied:-0}" -ge 3 ]
  assert $? "the readiness probe confirms schema version 3 or newer"
  printf '%s' "$readiness" | grep -q '"buildProvenance"'
  assert $? "the readiness group includes the build-provenance check"
else
  fail "readiness never reported UP"
  info "$(printf '%s' "$readiness" | head -c 400)"
fi

section "Only the business API is public"
[ "$(status_of GET /actuator/health)" != "200" ]
assert $? "/actuator is not reachable on the public port"
published="$(inspect "$api" '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} {{end}}{{end}}')"
info "published: ${published:-none}"
case "$published" in
  *9090*) fail "the management port is published to the host" ;;
  *) pass "the management port is not published to the host" ;;
esac

section "Runtime identity and filesystem"
proc_user="$(container_process_user "$api")"
info "the API process runs as: ${proc_user:-unknown}"
[ -n "$proc_user" ] && [ "$proc_user" != "root" ] && [ "$proc_user" != "0" ]
assert $? "the API container does not run as root"

readonly_fs="$(inspect "$api" '{{.HostConfig.ReadonlyRootfs}}')"
[ "$readonly_fs" = "true" ]
assert $? "the API container runs with a read-only root filesystem (got: $readonly_fs)"

runtime_json="$(body_of GET /api/v1/runtime)"
tmp_writable="$(json_field "$runtime_json" tmpDirWritable)"
root_writable="$(json_field "$runtime_json" rootFilesystemWritable)"
info "tmpDirWritable=$tmp_writable rootFilesystemWritable=$root_writable"
[ "$tmp_writable" = "true" ]
assert $? "the JVM still has a writable temp directory"
[ "$root_writable" = "false" ]
assert $? "the root filesystem is genuinely read-only from inside the process"

section "Build provenance survives the trip into the image"
traceable="$(json_field "$runtime_json" traceable)"
revision="$(json_field "$runtime_json" revision)"
version="$(json_field "$runtime_json" version)"
info "running revision=$revision version=$version"
[ "$traceable" = "true" ]
assert $? "the running application can name the commit it was built from"
[ "$revision" = "$REVISION" ]
assert $? "the running revision matches the commit under test"

section "The ledger actually works"
create='{"accountId":"ACC-EXAM","entryType":"CREDIT","amountMinor":250000,"currency":"EUR","idempotencyKey":"exam-key-1","batchId":"exam"}'
first="$(status_of POST /api/v1/entries "$create")"
replay="$(status_of POST /api/v1/entries "$create")"
[ "$first" = "201" ]; assert $? "the first write is accepted (got $first)"
[ "$replay" = "200" ]; assert $? "the replayed write is deduplicated rather than doubled (got $replay)"

debit='{"accountId":"ACC-EXAM","entryType":"DEBIT","amountMinor":50000,"currency":"EUR"}'
status_of POST /api/v1/entries "$debit" >/dev/null
balance="$(json_field "$(body_of GET /api/v1/accounts/ACC-EXAM/balance)" balanceMinor)"
info "balance after 2500.00 credit and 500.00 debit: ${balance:-?} minor units"
[ "${balance:-0}" = "200000" ]
assert $? "the balance is computed correctly across a credit and a debit"

bad='{"accountId":"ACC-EXAM","entryType":"CREDIT","amountMinor":1,"currency":"euro"}'
[ "$(status_of POST /api/v1/entries "$bad")" = "400" ]
assert $? "invalid input is rejected with 400"

finish
