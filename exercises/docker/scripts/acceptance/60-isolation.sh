#!/usr/bin/env bash
# Network isolation, image hygiene, and dev/prod separation.
. "$(dirname "$0")/_lib.sh"

section "Datastores are unreachable from the host"
for svc in "$SVC_DB" "$SVC_CACHE"; do
  c="$(cid "$svc")"
  [ -n "$c" ] || { fail "$svc container missing"; continue; }
  published="$(inspect "$c" '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} {{end}}{{end}}')"
  [ -z "$(printf '%s' "$published" | tr -d '[:space:]')" ]
  assert $? "$svc publishes nothing to the host (found: ${published:-none})"
done

# A raw port probe cannot tell your stack apart from an unrelated service that was
# already on this machine, so a hit here is a warning to investigate, not a verdict.
# The per-container published-port check above is the authoritative one.
for port in 5432 6379; do
  if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
    exec 3>&- 2>/dev/null
    warn "127.0.0.1:$port is open on this host - confirm it belongs to something other than this stack"
  else
    pass "127.0.0.1:$port is closed on the host"
  fi
done

section "Only the gateway is public"
g="$(cid "$SVC_GATEWAY")"
if [ -n "$g" ]; then
  published="$(inspect "$g" '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} {{end}}{{end}}')"
  info "gateway publishes: ${published:-none}"
  [ -n "$(printf '%s' "$published" | tr -d '[:space:]')" ]
  assert $? "the gateway publishes a host port"
fi

section "Production images carry no build-time baggage"
for svc in "$SVC_GATEWAY" "$SVC_WORKER"; do
  c="$(cid "$svc")"
  [ -n "$c" ] || continue
  image="$(inspect "$c" '{{.Config.Image}}')"
  size_bytes="$(docker image inspect --format '{{.Size}}' "$image" 2>/dev/null || echo 0)"
  info "$svc image $image is $(( size_bytes / 1048576 ))MiB"

  if docker exec "$c" sh -c 'test -d node_modules/nodemon -o -d node_modules/esbuild' 2>/dev/null; then
    fail "$svc runtime image still contains development dependencies"
  else
    pass "$svc runtime image has no development dependencies"
  fi

  nodeenv="$(docker exec "$c" sh -c 'echo $NODE_ENV' 2>/dev/null | tr -d '[:space:]')"
  [ "$nodeenv" = "production" ]
  assert $? "$svc runs with NODE_ENV=production (got: '${nodeenv:-unset}')"
done

section "A development target exists and is different"
for dir in api-gateway image-processor; do
  if grep -qiE '^[[:space:]]*FROM .* AS (dev|development)' "$dir/Dockerfile" 2>/dev/null; then
    pass "$dir/Dockerfile defines a development stage"
  else
    fail "$dir/Dockerfile has no development stage"
  fi
  if grep -qiE '^[[:space:]]*FROM .* AS (prod|production|runtime|release)' "$dir/Dockerfile" 2>/dev/null; then
    pass "$dir/Dockerfile defines a production stage"
  else
    fail "$dir/Dockerfile has no production stage"
  fi
done

section "Healthchecks are declared where they matter"
for svc in "$SVC_GATEWAY" "$SVC_WORKER" "$SVC_DB" "$SVC_CACHE"; do
  c="$(cid "$svc")"
  [ -n "$c" ] || continue
  has="$(inspect "$c" '{{if .State.Health}}yes{{else}}no{{end}}')"
  [ "$has" = "yes" ]
  assert $? "$svc has a container healthcheck"
done

section "Restart policy"
for svc in "$SVC_GATEWAY" "$SVC_WORKER"; do
  c="$(cid "$svc")"
  [ -n "$c" ] || continue
  policy="$(inspect "$c" '{{.HostConfig.RestartPolicy.Name}}')"
  [ -n "$policy" ] && [ "$policy" != "no" ]
  assert $? "$svc declares a restart policy (got: '${policy:-none}')"
done
mig="$(cid "$SVC_MIGRATOR")"
if [ -n "$mig" ]; then
  policy="$(inspect "$mig" '{{.HostConfig.RestartPolicy.Name}}')"
  [ "$policy" = "no" ] || [ "$policy" = "on-failure" ] || [ -z "$policy" ]
  assert $? "migrator does not restart forever (got: '${policy:-none}')"
fi

finish
