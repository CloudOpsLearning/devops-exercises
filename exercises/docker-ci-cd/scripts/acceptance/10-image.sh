#!/usr/bin/env bash
# Grades the artifact itself: how it was built, what ended up inside it, and whether a
# one-line code change costs you a full rebuild.
. "$(dirname "$0")/_lib.sh"

REVISION="$(git_revision)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

section "Cold build"
info "docker build --build-arg BUILD_REVISION=$REVISION --build-arg BUILD_VERSION=$BUILD_VERSION -t $IMAGE ."
build_cold() {
  docker build --no-cache \
    --build-arg BUILD_REVISION="$REVISION" \
    --build-arg BUILD_VERSION="$BUILD_VERSION" \
    -t "$IMAGE" . >"$SCRATCH/cold.log" 2>&1
}

cold_start=$(date +%s)
if build_cold; then
  cold_seconds=$(( $(date +%s) - cold_start ))
  pass "the image builds from a clean cache in ${cold_seconds}s using only the documented build args"
else
  # One retry, because a dependency mirror having a bad minute is not a design flaw.
  warn "the first clean build failed; retrying once"
  tail -8 "$SCRATCH/cold.log" | sed 's/^/          /'
  cold_start=$(date +%s)
  if build_cold; then
    cold_seconds=$(( $(date +%s) - cold_start ))
    pass "the image builds from a clean cache in ${cold_seconds}s (second attempt)"
  else
    fail "docker build failed twice from a clean cache"
    tail -25 "$SCRATCH/cold.log" | sed 's/^/          /'
    finish
  fi
fi

section "Image configuration"
size_mb=$(( $(docker image inspect --format '{{.Size}}' "$IMAGE") / 1048576 ))
info "image size: ${size_mb}MiB (ceiling ${IMAGE_MAX_MB}MiB)"
[ "$size_mb" -le "$IMAGE_MAX_MB" ]
assert $? "image is at or under the ${IMAGE_MAX_MB}MiB ceiling"

user="$(docker image inspect --format '{{.Config.User}}' "$IMAGE")"
[ -n "$user" ] && [ "$user" != "root" ] && [ "$user" != "0" ] && [ "$user" != "0:0" ]
assert $? "image declares a non-root USER (got: '${user:-empty}')"

entrypoint="$(docker image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE")"
info "entrypoint: $entrypoint"
printf '%s' "$entrypoint" | grep -q 'java'
assert $? "entrypoint invokes the JVM directly"
printf '%s' "$entrypoint" | grep -qE '"(/bin/)?(sh|bash)"' && \
  warn "entrypoint goes through a shell - make sure signals still reach the JVM"

for label in org.opencontainers.image.revision org.opencontainers.image.version org.opencontainers.image.source; do
  value="$(docker image inspect --format "{{index .Config.Labels \"$label\"}}" "$IMAGE")"
  [ -n "$value" ] && [ "$value" != "<no value>" ]
  assert $? "$label is set (got: '${value}')"
done
label_revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$IMAGE")"
[ "$label_revision" = "$REVISION" ]
assert $? "the revision label matches the commit the suite built ($REVISION)"

section "Nothing secret and nothing unnecessary in the layers"
if docker image history --no-trunc "$IMAGE" 2>/dev/null \
     | grep -iE '(password|secret|token|credential)[=:][^ ]{4,}' | grep -qv 'BUILD_'; then
  fail "docker history exposes something credential shaped"
  docker image history --no-trunc "$IMAGE" | grep -iE '(password|secret|token)' | head -3 | sed 's/^/          /'
else
  pass "docker history exposes no credentials"
fi

env_json="$(docker image inspect --format '{{json .Config.Env}}' "$IMAGE")"
if printf '%s' "$env_json" | grep -qiE '(PASSWORD|SECRET|TOKEN|CREDENTIAL)='; then
  fail "the image carries a credential in its baked-in environment"
  info "$env_json"
else
  pass "the image environment carries no credentials"
fi

# Reading the filesystem through `docker export` works even for images with no shell.
container="$(docker create "$IMAGE" 2>/dev/null)"
docker export "$container" 2>/dev/null | tar -t 2>/dev/null > "$SCRATCH/fs.txt"
docker rm -f "$container" >/dev/null 2>&1
if [ -s "$SCRATCH/fs.txt" ]; then
  jar_count=$(grep -c '\.jar$' "$SCRATCH/fs.txt" || true)
  info "jar files in the image: ${jar_count} (a fat jar image contains exactly one)"
  [ "${jar_count:-0}" -ge 10 ]
  assert $? "the application is unpacked into layers rather than shipped as one fat jar"

  if grep -qE '\.m2/repository|/usr/share/maven|maven-3' "$SCRATCH/fs.txt"; then
    fail "the runtime image still contains a Maven installation or repository"
  else
    pass "no Maven toolchain leaked into the runtime image"
  fi

  if grep -qE '\.java$' "$SCRATCH/fs.txt"; then
    fail "the runtime image contains Java source files"
  else
    pass "no source files in the runtime image"
  fi
else
  warn "could not export the image filesystem - skipping content checks"
fi

section "One artifact, two jobs"
migrate_out="$(docker run --rm "$IMAGE" --migrate 2>&1)"
migrate_code=$?
info "exit code with --migrate and no database configuration: $migrate_code"
[ "$migrate_code" -eq 64 ]
assert $? "the same image runs the migration job (--migrate exits 64 when unconfigured, not 'command not found')"
printf '%s' "$migrate_out" | grep -q 'SETTLEMENT_DB_URL'
assert $? "the migration job explains what configuration it needs"

section "A source change must not cost a full rebuild"
# The probe is a new source file rather than an edit to yours: BuildKit caches on content,
# and this project builds reproducibly, so a comment would change nothing at all.
PROBE_FILE="settlement-api/src/main/java/com/kestrel/settlement/api/AcceptanceCacheProbe.java"
restore_probe() { rm -f "$PROBE_FILE"; }
trap 'restore_probe; rm -rf "$SCRATCH"' EXIT
printf 'package com.kestrel.settlement.api;\n\nfinal class AcceptanceCacheProbe {\n    static final String STAMP = "%s";\n\n    private AcceptanceCacheProbe() {}\n}\n' \
  "$(date +%s)" > "$PROBE_FILE"

warm_start=$(date +%s)
if docker build \
      --build-arg BUILD_REVISION="$REVISION" \
      --build-arg BUILD_VERSION="$BUILD_VERSION" \
      -t "${IMAGE}-rebuild" . >"$SCRATCH/warm.log" 2>&1; then
  warm_seconds=$(( $(date +%s) - warm_start ))
  info "cold build ${cold_seconds}s, rebuild after touching one source file ${warm_seconds}s"
  if grep -qiE 'Downloading from|Downloaded from' "$SCRATCH/warm.log"; then
    fail "the rebuild downloaded dependencies again - the dependency layer is not cached"
  else
    pass "the rebuild resolved no dependencies from the network"
  fi
  [ "$warm_seconds" -le $(( cold_seconds * 80 / 100 + 5 )) ]
  assert $? "the rebuild is meaningfully faster than a clean build (${warm_seconds}s vs ${cold_seconds}s)"

  shared=$(comm -12 \
    <(docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$IMAGE" | sort) \
    <(docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "${IMAGE}-rebuild" | sort) \
    | grep -c 'sha256' || true)
  total=$(docker image inspect --format '{{len .RootFS.Layers}}' "${IMAGE}-rebuild")
  info "layers shared with the previous build: ${shared}/${total}"
  [ "${shared:-0}" -ge $(( total - 2 )) ]
  assert $? "a source-only change invalidates at most two layers"
  [ "${shared:-0}" -lt "$total" ]
  assert $? "the source change really did produce a new image layer (the probe was effective)"
  docker image rm -f "${IMAGE}-rebuild" >/dev/null 2>&1
else
  fail "the rebuild failed"
  tail -20 "$SCRATCH/warm.log" | sed 's/^/          /'
fi
restore_probe

section "The image has to build for the platform production runs on"
if docker buildx build --platform linux/amd64,linux/arm64 \
      --build-arg BUILD_REVISION="$REVISION" \
      --build-arg BUILD_VERSION="$BUILD_VERSION" \
      -o type=cacheonly . >"$SCRATCH/multiarch.log" 2>&1; then
  pass "the Dockerfile builds for linux/amd64 and linux/arm64"
else
  fail "the multi-architecture build failed - production is amd64 and your laptop probably is not"
  tail -20 "$SCRATCH/multiarch.log" | sed 's/^/          /'
fi

finish
