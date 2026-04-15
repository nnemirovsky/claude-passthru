#!/usr/bin/env bash
# wezterm stub for overlay.bats.
#
# Mimics the subset of `wezterm` that scripts/overlay.sh invokes. Overlay
# calls `wezterm cli split-pane -- bash $DIALOG`. We skip the `cli split-pane`
# tokens, then everything after `--` is the inner command that a real
# wezterm would spawn in the new pane. We exec it inline so the dialog runs.

set -u

LOG="${PASSTHRU_STUB_WEZTERM_LOG:-/dev/null}"

{
  printf 'wezterm'
  for a in "$@"; do
    printf ' %s' "$a"
  done
  printf '\n'
} >> "$LOG" 2>/dev/null || true

# Find the `--` separator. Everything after is the inner command.
inner_start=0
i=0
for a in "$@"; do
  i=$((i + 1))
  if [ "$a" = "--" ]; then
    inner_start="$i"
    break
  fi
done

if [ "$inner_start" -gt 0 ]; then
  shift "$inner_start"
  if [ "$#" -gt 0 ]; then
    "$@"
    exit $?
  fi
fi

exit 0
