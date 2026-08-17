#!/usr/bin/env bash
# Runs the whole suite in order and prints a scorecard.
# Stage 50 only reaches the registry when IMAGE_REF is set.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGES=(00-preflight 10-image 20-runtime 30-resilience 40-pipeline 50-registry)

declare -a RESULTS=()
overall=0

for stage in "${STAGES[@]}"; do
  printf '\n\033[1m################  %s  ################\033[0m\n' "$stage"
  if bash "$HERE/$stage.sh"; then
    RESULTS+=("PASS  $stage")
  else
    RESULTS+=("FAIL  $stage")
    overall=1
  fi
done

printf '\n\033[1m################  SCORECARD  ################\033[0m\n'
for line in "${RESULTS[@]}"; do
  case "$line" in
    PASS*) printf '\033[32m%s\033[0m\n' "$line" ;;
    *)     printf '\033[31m%s\033[0m\n' "$line" ;;
  esac
done

if [ "$overall" -eq 0 ]; then
  printf '\n\033[32mAll stages passed.\033[0m Submit the bundle listed in the README.\n'
else
  printf '\n\033[31mNot there yet.\033[0m Read the failing stage, then read the build log or the container logs.\n'
fi

exit "$overall"
