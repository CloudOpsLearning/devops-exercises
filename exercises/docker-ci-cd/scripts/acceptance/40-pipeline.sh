#!/usr/bin/env bash
# Static grading of the delivery pipeline. This stage never runs your pipeline - it
# reads it. Everything asserted here is something an auditor could ask you to point at.
. "$(dirname "$0")/_lib.sh"

FILES="$(pipeline_files)"
if [ -z "$FILES" ]; then
  fail "no pipeline definition found (.github/workflows/*.yml, .gitlab-ci.yml or Jenkinsfile)"
  finish
fi
info "grading: $(printf '%s' "$FILES" | tr '\n' ' ')"

# Written to a file rather than piped: `grep -q` exits early, and under pipefail a
# SIGPIPE on the writing side would report "no match" for a pattern that did match.
TEXT_FILE="$(mktemp)"
trap 'rm -f "$TEXT_FILE"' EXIT
pipeline_text > "$TEXT_FILE"

has() { grep -qiE -e "$1" "$TEXT_FILE"; }
require() { if has "$1"; then pass "$2"; else fail "$2"; fi }
suggest() { if has "$1"; then pass "$2"; else warn "$2"; fi }
forbid() { if has "$1"; then fail "$2"; else pass "$2"; fi }

section "The pipeline builds and tests what it ships"
require 'mvn|maven|mvnw|gradle' "the pipeline builds with the project's build tool"
require '(mvn|mvnw).*(verify|failsafe|integration-test)' "the integration suite runs in the pipeline, not only on a laptop"
if has '(mvn|mvnw).*verify.*(-DskipTests|-DskipITs|-Dmaven\.test\.skip)'; then
  fail "the verify step is invoked with tests skipped"
else
  pass "tests are not skipped in the pipeline"
fi
suggest 'cache|actions/cache|\.m2' "the Maven repository is cached between runs"

section "The image is built for production's architecture"
require 'buildx|setup-buildx-action' "the image is built with buildx"
require 'platforms?:.*linux/amd64|--platform.*linux/amd64' "linux/amd64 is built"
require 'platforms?:.*arm64|--platform.*arm64' "linux/arm64 is built"
suggest 'setup-qemu-action|qemu' "cross-platform emulation is set up explicitly"
require 'cache-from|cache-to|type=gha|type=registry,ref' "the build layer cache is wired up"

section "The image is stamped with its provenance"
require 'BUILD_REVISION' "BUILD_REVISION is passed as a build argument"
require 'BUILD_VERSION' "BUILD_VERSION is passed as a build argument"
require 'github\.sha|CI_COMMIT_SHA|GIT_COMMIT|rev-parse' "the commit sha is part of the build inputs"
suggest 'org\.opencontainers\.image|labels:|metadata-action' "OCI labels are produced by the pipeline"
suggest 'sbom|syft|spdx|cyclonedx' "an SBOM is produced for each published image"

section "Credentials"
require 'secrets\.|CI_REGISTRY_PASSWORD|DOCKERHUB_TOKEN|credentialsId' "registry credentials come from the CI secret store"
require 'login-action|docker login|password-stdin' "the pipeline authenticates to the registry explicitly"
forbid 'docker login.*-p[[:space:]]+[A-Za-z0-9]' "no password is passed on a command line"
forbid 'echo.*(secrets\.|DOCKERHUB_TOKEN|CI_REGISTRY_PASSWORD)' "no secret is echoed into the log"
forbid '--build-arg.*(PASSWORD|TOKEN|SECRET)' "no secret is passed as a build argument"

section "Tagging discipline"
require 'tags:|-t[[:space:]]|--tag' "the pipeline tags the image explicitly"
if has 'sha-|CI_COMMIT_SHORT_SHA|github\.sha|rev-parse'; then
  pass "every image is addressable by commit"
else
  fail "images are not tagged with the commit they were built from"
fi
if has 'latest'; then
  if has 'enable=|if:|rules:|only:|when:'; then
    pass "the 'latest' tag is guarded by a condition"
    info "state in EVIDENCE.md that the condition is a release, not a branch push"
  else
    fail "'latest' is applied unconditionally"
  fi
else
  pass "no unconditional 'latest' tag"
fi
require 'imagetools inspect|manifest inspect|crane|skopeo|fail-if-exists|no-overwrite' \
  "the pipeline checks whether a tag already exists before publishing over it"

section "Push is a decision, not a default"
require 'if:|rules:|when:|only:|github\.event_name|CI_PIPELINE_SOURCE' "publishing is conditional"
if has 'pull_request|merge_request'; then
  pass "pull requests are handled explicitly"
else
  fail "nothing in the pipeline distinguishes a pull request from a merge to the main branch"
fi

section "Supply chain gates"
require 'trivy|grype|docker scout|snyk|clair' "the image is scanned for vulnerabilities"
require 'exit-code|severity|--fail|failOn|ignore-unfixed' "the scan can actually fail the pipeline"
if has 'digest'; then
  pass "the pipeline works with the image digest, so what was scanned is what is published"
else
  fail "nothing references the built image digest - a rebuild between scan and push publishes an unscanned artifact"
fi
suggest 'provenance:|attest|cosign|sigstore' "provenance or signing is produced"

section "Pipeline hygiene"
if printf '%s' "$FILES" | grep -q '.github/workflows'; then
  suggest 'permissions:' "the workflow declares least-privilege permissions"
  suggest 'concurrency:' "the workflow declares a concurrency group"
  suggest 'timeout-minutes' "jobs have a timeout"
else
  suggest 'interruptible|timeout' "jobs are interruptible and time-bounded"
fi

finish
