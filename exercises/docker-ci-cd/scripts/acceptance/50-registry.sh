#!/usr/bin/env bash
# Grades what actually reached Docker Hub, and the evidence you wrote about it.
#
#   IMAGE_REF=docker.io/you/settlement-api:1.4.2 ./scripts/acceptance/50-registry.sh
. "$(dirname "$0")/_lib.sh"

section "EVIDENCE.md"
if [ ! -f EVIDENCE.md ]; then
  fail "EVIDENCE.md is missing"
  finish
fi
words=$(wc -w < EVIDENCE.md | tr -d '[:space:]')
info "EVIDENCE.md is $words words"
[ "${words:-0}" -ge 350 ]
assert $? "EVIDENCE.md is a real write-up rather than a stub"

if grep -qiE '(^|[^a-z])(TODO|TBD|FIXME|fill in|<your|xxx+)' EVIDENCE.md; then
  fail "EVIDENCE.md still contains placeholders"
  grep -inE '(TODO|TBD|FIXME|fill in|<your|xxx+)' EVIDENCE.md | head -5 | sed 's/^/          /'
else
  pass "EVIDENCE.md has no leftover placeholders"
fi

for topic in image pipeline architecture scan tag memory; do
  grep -qi "$topic" EVIDENCE.md
  assert $? "EVIDENCE.md covers '$topic'"
done

if grep -qE 'sha256:[0-9a-f]{16,}' EVIDENCE.md; then
  pass "EVIDENCE.md records an image digest"
else
  fail "EVIDENCE.md records no image digest - a tag is not an identity"
fi

if grep -qiE 'https?://(github|gitlab)\.com/[^ )]+/(actions/runs|-/pipelines|-/jobs)' EVIDENCE.md; then
  pass "EVIDENCE.md links a concrete pipeline run"
else
  fail "EVIDENCE.md does not link the pipeline run that produced the image"
fi

if grep -qiE '(password|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/_-]{8,}|dckr_pat_' EVIDENCE.md; then
  fail "EVIDENCE.md appears to contain a credential"
else
  pass "EVIDENCE.md contains no credentials"
fi

section "The published image"
if [ -z "${IMAGE_REF:-}" ]; then
  warn "IMAGE_REF is not set, so the registry itself was not inspected"
  info "re-run as: IMAGE_REF=docker.io/<user>/settlement-api:<tag> $0"
  finish
fi

info "inspecting $IMAGE_REF"
raw="$(docker buildx imagetools inspect --raw "$IMAGE_REF" 2>&1)"
if printf '%s' "$raw" | grep -q 'mediaType'; then
  pass "the tag exists in the registry and is readable"
else
  fail "could not read $IMAGE_REF from the registry"
  info "$(printf '%s' "$raw" | head -3)"
  finish
fi

if printf '%s' "$raw" | grep -qE 'image.index|manifest.list'; then
  pass "the tag resolves to a multi-platform manifest list"
else
  fail "the tag is a single-platform manifest - production and your laptop cannot both use it"
fi

platforms="$(docker buildx imagetools inspect "$IMAGE_REF" 2>/dev/null | grep -i 'Platform:' | awk '{print $2}' | tr '\n' ' ')"
info "platforms: ${platforms:-none}"
printf '%s' "$platforms" | grep -q 'linux/amd64'
assert $? "linux/amd64 is published"
printf '%s' "$platforms" | grep -q 'linux/arm64'
assert $? "linux/arm64 is published"

digest="$(docker buildx imagetools inspect "$IMAGE_REF" --format '{{.Manifest.Digest}}' 2>/dev/null)"
info "registry digest: ${digest:-unknown}"
if [ -n "$digest" ] && grep -qF "$digest" EVIDENCE.md; then
  pass "the digest in EVIDENCE.md matches what is in the registry"
else
  fail "EVIDENCE.md does not record this exact digest (${digest:-unknown})"
fi

section "Metadata on the published image"
if docker pull -q "$IMAGE_REF" >/dev/null 2>&1; then
  user="$(docker image inspect --format '{{.Config.User}}' "$IMAGE_REF")"
  [ -n "$user" ] && [ "$user" != "root" ] && [ "$user" != "0" ]
  assert $? "the published image runs as a non-root user (got '${user:-empty}')"

  for label in org.opencontainers.image.revision org.opencontainers.image.version org.opencontainers.image.source; do
    value="$(docker image inspect --format "{{index .Config.Labels \"$label\"}}" "$IMAGE_REF")"
    [ -n "$value" ] && [ "$value" != "<no value>" ]
    assert $? "$label is present on the published image ('$value')"
  done

  env_json="$(docker image inspect --format '{{json .Config.Env}}' "$IMAGE_REF")"
  if printf '%s' "$env_json" | grep -qiE '(PASSWORD|SECRET|TOKEN|CREDENTIAL)='; then
    fail "the published image carries a credential in its environment"
  else
    pass "the published image carries no credentials in its environment"
  fi
else
  warn "could not pull $IMAGE_REF for metadata inspection"
fi

section "Tag immutability"
base_ref="${IMAGE_REF%:*}"
latest_digest="$(docker buildx imagetools inspect "${base_ref}:latest" --format '{{.Manifest.Digest}}' 2>/dev/null)"
if [ -z "$latest_digest" ]; then
  pass "no floating ':latest' tag exists for this repository"
elif [ "$latest_digest" = "$digest" ]; then
  pass "':latest' points at the same digest as the immutable tag"
else
  warn "':latest' points at $latest_digest, a different artifact than $IMAGE_REF - explain that in EVIDENCE.md"
fi

finish
