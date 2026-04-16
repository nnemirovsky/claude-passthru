#!/usr/bin/env bash
# kitty stub for overlay.bats.
#
# Mimics the subset of `kitty` that scripts/overlay.sh invokes. Overlay calls
# `kitty @ launch --type=overlay --no-response bash $DIALOG`. We find the
# first non-flag argument after @ launch (which should be `bash`) and exec
# that with the remaining argv so the dialog script runs like it would inside
# a real kitty overlay window.
#
# Any other kitty subcommand is no-op.

set -u

LOG="${PASSTHRU_STUB_KITTY_LOG:-/dev/null}"

{
  printf 'kitty'
  for a in "$@"; do
    printf ' %s' "$a"
  done
  printf '\n'
} >> "$LOG" 2>/dev/null || true

# Expected argv shape:
#   kitty @ launch [flags...] bash $DIALOG
# Strip `@ launch`, skip over --flag / --flag=value, then exec the rest.
if [ "${1:-}" = "@" ]; then
  shift
fi
if [ "${1:-}" = "launch" ]; then
  shift
fi

# Drop leading --flag / --flag=value tokens until we hit a non-flag (the
# inner command, e.g. `bash`).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --*)
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -gt 0 ]; then
  "$@"
  exit $?
fi

exit 0
