#!/usr/bin/env bash
# Runs the whole acceptance suite in order and prints a scorecard.
# Any single failing stage fails the exam.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGES=(00-preflight 10-cold-boot 20-load 30-memory 40-restart 50-ownership 60-isolation)

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
  printf '\n\033[32mAll stages passed.\033[0m Write up your reasoning and submit.\n'
else
  printf '\n\033[31mThe system is not correct yet.\033[0m Read the failing stage, then read the logs.\n'
fi

exit "$overall"
