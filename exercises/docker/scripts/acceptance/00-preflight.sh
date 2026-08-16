#!/usr/bin/env bash
# Static checks. These run before anything is started and grade what you wrote,
# not what happens to work on your laptop.
. "$(dirname "$0")/_lib.sh"

section "Deliverables present"
for f in api-gateway/Dockerfile image-processor/Dockerfile db-migrator/Dockerfile; do
  [ -f "$f" ]; assert $? "$f exists"
done
[ -n "$COMPOSE_FILE" ]; assert $? "compose file found ($COMPOSE_FILE)"
[ -f .dockerignore ] || [ -f api-gateway/.dockerignore ]
assert $? "at least one .dockerignore exists"
[ -f .env ]; assert $? ".env exists (it must not be committed)"

section "Compose file is valid and complete"
dc config >/dev/null 2>&1; assert $? "docker compose config parses"
DECLARED_SERVICES="$(dc config --services 2>/dev/null)"
for svc in "$SVC_GATEWAY" "$SVC_WORKER" "$SVC_MIGRATOR" "$SVC_DB" "$SVC_CACHE"; do
  printf '%s\n' "$DECLARED_SERVICES" | grep -qx "$svc"
  assert $? "service '$svc' is declared"
done

section "No secrets baked into source control"
if grep -rInE '(POSTGRES_PASSWORD|REDIS_PASSWORD)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9]' \
     --include='*.yml' --include='*.yaml' --include='Dockerfile' . 2>/dev/null \
   | grep -vE '\$\{|_FILE|\.env|secrets' | grep -q .; then
  fail "a literal credential appears in a Dockerfile or compose file"
  grep -rInE '(POSTGRES_PASSWORD|REDIS_PASSWORD)[[:space:]]*[:=]' --include='*.yml' --include='*.yaml' --include='Dockerfile' . \
    | grep -vE '\$\{|_FILE' | sed 's/^/          /'
else
  pass "no literal credentials in Dockerfiles or compose files"
fi

if [ -f .gitignore ] && grep -q '^\.env$' .gitignore; then
  pass ".env is gitignored"
else
  fail ".env is not listed in .gitignore"
fi

section "Datastores are not reachable from the host network"
for svc in "$SVC_DB" "$SVC_CACHE"; do
  if dc config 2>/dev/null | awk -v s="  $svc:" '
      $0 == s {inside=1; next}
      /^  [a-zA-Z0-9_-]+:$/ {inside=0}
      inside && /^[[:space:]]+ports:/ {found=1}
      END {exit !found}'; then
    fail "$svc publishes ports to the host"
  else
    pass "$svc publishes no host ports"
  fi
done

section "Build targets"
grep -qiE '^[[:space:]]*FROM .* AS ' api-gateway/Dockerfile 2>/dev/null
assert $? "api-gateway/Dockerfile uses named build stages"
grep -qiE '^[[:space:]]*FROM .* AS ' image-processor/Dockerfile 2>/dev/null
assert $? "image-processor/Dockerfile uses named build stages"
grep -qiE '^[[:space:]]*USER ' api-gateway/Dockerfile 2>/dev/null
assert $? "api-gateway/Dockerfile drops privileges with USER"
grep -qiE '^[[:space:]]*USER ' image-processor/Dockerfile 2>/dev/null
assert $? "image-processor/Dockerfile drops privileges with USER"
grep -qiE '^[[:space:]]*USER ' db-migrator/Dockerfile 2>/dev/null
assert $? "db-migrator/Dockerfile drops privileges with USER"

finish
