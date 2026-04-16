#!/usr/bin/env bash
# tmux stub for overlay.bats.
#
# Mimics the subset of `tmux` that scripts/overlay.sh invokes. Records the
# argv it was called with to $PASSTHRU_STUB_TMUX_LOG (so tests can assert on
# the popup flags) and, when invoked with `display-popup -E ... -- bash
# $DIALOG`, executes the trailing `bash $DIALOG` so the overlay-dialog script
# runs and writes its result file the same way a real tmux popup would.
#
# Any other tmux subcommand (tmux --version, etc.) is silently no-op so that
# things like `command -v tmux` + metadata probes do not crash.

set -u

LOG="${PASSTHRU_STUB_TMUX_LOG:-/dev/null}"

# Record full argv, space-separated, one invocation per line.
{
  printf 'tmux'
  for a in "$@"; do
    printf ' %s' "$a"
  done
  printf '\n'
} >> "$LOG" 2>/dev/null || true

# Locate the `--` separator. Everything after it is the inner command.
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
  # Execute the inner command. It inherits the current env, which is how real
  # tmux popups would see our PASSTHRU_OVERLAY_* vars.
  if [ "$#" -gt 0 ]; then
    "$@"
    exit $?
  fi
fi

exit 0
