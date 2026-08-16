#!/usr/bin/env bash
# File ownership across the container/host boundary.
# An operator with no sudo must be able to clean up after this stack.
. "$(dirname "$0")/_lib.sh"

wait_for_ready 60 || warn "gateway not ready - running the ownership checks anyway"

section "Runtime identity inside the containers"
for svc in "$SVC_GATEWAY" "$SVC_WORKER" ; do
  c="$(cid "$svc")"
  [ -n "$c" ] || { fail "$svc container missing"; continue; }
  ids="$(docker exec "$c" id 2>/dev/null)"
  info "$svc: $ids"
  printf '%s' "$ids" | grep -q 'uid=0('
  if [ $? -eq 0 ]; then fail "$svc runs as root"; else pass "$svc runs as a non-root user"; fi
done

mig="$(cid "$SVC_MIGRATOR")"
if [ -n "$mig" ]; then
  cfg_user="$(inspect "$mig" '{{.Config.User}}')"
  [ -n "$cfg_user" ] && [ "$cfg_user" != "0" ] && [ "$cfg_user" != "root" ]
  assert $? "migrator container declares a non-root user (User='$cfg_user')"
fi

section "Artifact permissions"
w="$(cid "$SVC_WORKER")"
if [ -n "$w" ]; then
  perms="$(docker exec "$w" sh -c 'ls -ld /scratch /scratch/processed 2>/dev/null' || true)"
  printf '%s\n' "$perms" | sed 's/^/          /'
  sample="$(docker exec "$w" sh -c 'ls -l /scratch/processed/*.json 2>/dev/null | head -1' || true)"
  info "sample artifact: ${sample:-none}"
  if [ -n "$sample" ]; then
    printf '%s' "$sample" | grep -qE '^-rw-r-----'
    assert $? "artifacts are written 0640 (group readable, never world readable)"
  else
    warn "no artifacts on disk yet - run 20-load.sh first"
  fi
fi

section "The gateway can read what the worker wrote"
body="$(curl -sS -m 10 "$GATEWAY_URL/assets" 2>/dev/null)"
if printf '%s' "$body" | grep -q '"readable":false'; then
  fail "the gateway cannot read the processed directory (permission or group mismatch)"
  printf '%s' "$body" | grep -o '"error":"[^"]*"' | head -1 | sed 's/^/          /'
else
  pass "the gateway reads the shared processed directory"
fi

section "Host-side cleanup without privilege escalation"
host_uid="$(id -u)"
info "host uid: $host_uid"

if [ ! -d "$SCRATCH_DIR_HOST/processed" ]; then
  warn "shared-scratch/processed does not exist on the host - if you used a named volume instead of a bind mount, state that decision in your write-up"
else
  owner_uid="$(stat -f '%u' "$SCRATCH_DIR_HOST/processed" 2>/dev/null || stat -c '%u' "$SCRATCH_DIR_HOST/processed" 2>/dev/null)"
  info "shared-scratch/processed is owned by uid $owner_uid"
  [ "$owner_uid" != "0" ]
  assert $? "the shared directory is not root-owned on the host"

  probe="$SCRATCH_DIR_HOST/processed/.cleanup-probe"
  if docker exec "$w" sh -c 'echo probe > /scratch/processed/.cleanup-probe' 2>/dev/null; then
    if rm -f "$probe" 2>/dev/null; then
      pass "the host operator can delete container-written files without sudo"
    else
      fail "the host operator cannot delete container-written files without sudo"
      ls -l "$probe" 2>/dev/null | sed 's/^/          /'
    fi
  else
    warn "could not create a probe file inside the container"
  fi
fi

section "Environment contract is honoured, not bypassed"
for svc in "$SVC_GATEWAY" "$SVC_WORKER"; do
  c="$(cid "$svc")"
  [ -n "$c" ] || continue
  declared_uid="$(docker exec "$c" sh -c 'echo $APP_UID' 2>/dev/null | tr -d '[:space:]')"
  actual_uid="$(docker exec "$c" id -u 2>/dev/null | tr -d '[:space:]')"
  [ -n "$declared_uid" ] && [ "$declared_uid" = "$actual_uid" ]
  assert $? "$svc: APP_UID ($declared_uid) matches the effective uid ($actual_uid)"
done

finish
