#!/usr/bin/env bash
# Static grading. Nothing is started here - this stage reads what you wrote.
. "$(dirname "$0")/_lib.sh"

section "Deliverables present"
[ -f Dockerfile ]; assert $? "Dockerfile exists at the project root"
[ -f .dockerignore ]; assert $? ".dockerignore exists"
[ -n "$COMPOSE_FILE" ]; assert $? "compose file exists (${COMPOSE_FILE:-none found})"
[ -f EVIDENCE.md ]; assert $? "EVIDENCE.md exists"
[ -n "$(pipeline_files)" ]; assert $? "a pipeline definition exists ($(pipeline_files | tr '\n' ' '))"

section "Build context hygiene"
grep -qE '(^|/)target/?$|(^|/)target/\*\*?$|^\*\*/target' .dockerignore 2>/dev/null
assert $? ".dockerignore excludes Maven target directories"
grep -qE '^\.git/?$|^\*\*/\.git' .dockerignore 2>/dev/null
assert $? ".dockerignore excludes .git"
if [ -f .gitignore ] && grep -qE '^\.env$' .gitignore; then
  pass ".env is gitignored"
else
  fail ".env is not listed in .gitignore"
fi

section "Dockerfile structure"
stages="$(grep -ciE '^[[:space:]]*FROM ' Dockerfile 2>/dev/null || echo 0)"
[ "${stages:-0}" -ge 2 ]; assert $? "Dockerfile is multi-stage (found $stages FROM instructions)"
grep -qiE '^[[:space:]]*FROM .+ AS [a-z0-9_-]+' Dockerfile
assert $? "build stages are named"
grep -qiE '^[[:space:]]*USER ' Dockerfile
assert $? "the runtime stage drops privileges with USER"
grep -qiE '^[[:space:]]*ENTRYPOINT[[:space:]]*\[' Dockerfile
assert $? "ENTRYPOINT uses exec form (a JSON array), so the JVM receives signals directly"

# A FROM may legitimately reference an earlier stage by name; only real registry
# references have to be pinned.
STAGE_NAMES="$(grep -iE '^[[:space:]]*FROM ' Dockerfile 2>/dev/null \
  | sed -nE 's/.*[[:space:]][Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+).*/\1/p')"
unpinned=""
while read -r image; do
  [ -n "$image" ] || continue
  if printf '%s\n' "$STAGE_NAMES" | grep -qix "$image"; then continue; fi
  case "$image" in
    *@sha256:*) ;;                      # digest pinned, ideal
    *:latest) unpinned="$unpinned $image" ;;
    *:*) ;;                             # tag pinned, acceptable
    *) unpinned="$unpinned $image" ;;   # no tag at all
  esac
done <<EOF
$(grep -iE '^[[:space:]]*FROM ' Dockerfile 2>/dev/null | awk '{print $2}')
EOF
if [ -n "$(printf '%s' "$unpinned" | tr -d '[:space:]')" ]; then
  fail "a base image is unpinned (:latest or no tag):$unpinned"
else
  pass "every base image reference is pinned to a tag or digest"
fi

section "Tests do not run inside the image build"
if grep -qiE '^[[:space:]]*RUN .*(mvn|maven|\./mvnw).*(^| )(test|verify|integration-test)( |$)' Dockerfile \
   && ! grep -qiE '^[[:space:]]*RUN .*(-DskipTests|-Dmaven\.test\.skip|-DskipITs)' Dockerfile; then
  fail "the image build runs the test phase - the integration suite needs a container runtime the builder does not have"
else
  pass "the image build does not run the test phase"
fi

section "No credentials in the build"
if grep -qiE '^[[:space:]]*(ARG|ENV)[[:space:]]+[A-Z_]*(PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL)' Dockerfile; then
  fail "the Dockerfile declares an ARG/ENV that carries a credential into image metadata"
  grep -inE '^[[:space:]]*(ARG|ENV)[[:space:]]+[A-Z_]*(PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL)' Dockerfile | sed 's/^/          /'
else
  pass "no credential-shaped ARG or ENV in the Dockerfile"
fi

if grep -rInE '(PASSWORD|SECRET|TOKEN)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/._-]{6,}' \
     Dockerfile "$COMPOSE_FILE" $(pipeline_files) 2>/dev/null \
   | grep -vE '\$\{|\$\(|secrets\.|_FILE|<<|example|CHANGE' | grep -q .; then
  fail "a literal credential appears in a committed build or deployment file"
  grep -rInE '(PASSWORD|SECRET|TOKEN)[[:space:]]*[:=]' Dockerfile "$COMPOSE_FILE" $(pipeline_files) 2>/dev/null \
    | grep -vE '\$\{|\$\(|secrets\.|_FILE' | head -5 | sed 's/^/          /'
else
  pass "no literal credentials in Dockerfile, compose file or pipeline"
fi

section "Compose topology"
if dc config >/dev/null 2>&1; then
  pass "docker compose config parses"
  services="$(dc config --services 2>/dev/null)"
  for svc in "$SVC_API" "$SVC_DB" "$SVC_MIGRATOR"; do
    printf '%s\n' "$services" | grep -qx "$svc"
    assert $? "service '$svc' is declared"
  done

  rendered="$(dc config 2>/dev/null)"
  if printf '%s' "$rendered" | awk -v s="  $SVC_DB:" '
      $0 == s {inside=1; next}
      /^  [a-zA-Z0-9_-]+:$/ {inside=0}
      inside && /^[[:space:]]+ports:/ {found=1}
      END {exit !found}'; then
    fail "$SVC_DB publishes ports to the host"
  else
    pass "$SVC_DB publishes no host ports"
  fi

  if printf '%s' "$rendered" | grep -qE '"?9090"?:9090|:9090"?$'; then
    fail "the management port (9090) is published to the host"
  else
    pass "the management port is not published to the host"
  fi
else
  fail "docker compose config does not parse"
fi

finish
