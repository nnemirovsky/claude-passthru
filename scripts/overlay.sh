#!/usr/bin/env bash
# claude-passthru terminal-overlay launcher.
#
# Detects the active terminal multiplexer via env vars ($TMUX, $KITTY_WINDOW_ID,
# $WEZTERM_PANE), invokes its "popup" primitive with scripts/overlay-dialog.sh
# as the entry point, and hands the dialog a pre-agreed result file where the
# user's choice lands.
#
# Contract:
#   Caller exports:
#     PASSTHRU_OVERLAY_TOOL_NAME           - the tool_name being gated.
#     PASSTHRU_OVERLAY_TOOL_INPUT_JSON     - the tool_input as compact JSON.
#     PASSTHRU_OVERLAY_RESULT_FILE         - absolute path where the dialog
#                                            writes its verdict. Caller reads
#                                            this file after overlay.sh exits.
#   Optional:
#     PASSTHRU_OVERLAY_TIMEOUT=<seconds>   - dialog budget, default 60s.
#     PASSTHRU_OVERLAY_TEST_ANSWER=<val>   - test short-circuit (bypasses the
#                                            real TUI keypress loop). Accepted
#                                            values: yes_once | yes_always |
#                                            no_once | no_always | cancel.
#
# Exit codes:
#   0 - popup ran to completion; result file may or may not have been written
#       (caller treats absent/empty content as cancel).
#   1 - no supported multiplexer available (neither env var set OR binary
#       missing from PATH for the one that IS set).
#   2 - popup launch failure (multiplexer detected but the popup command
#       itself errored).
#
# This script is the launcher only. The actual menu rendering happens inside
# overlay-dialog.sh, which runs in the popup context. Separation keeps the
# launcher testable via stubs without depending on interactive IO.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate sibling scripts
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/overlay-dialog.sh" ]; then
  _PASSTHRU_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  _PASSTHRU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_PLUGIN_ROOT="$(cd "${_PASSTHRU_SCRIPT_DIR}/.." && pwd)"
fi

DIALOG="${_PASSTHRU_PLUGIN_ROOT}/scripts/overlay-dialog.sh"
if [ ! -f "$DIALOG" ]; then
  printf 'overlay.sh: cannot locate dialog script: %s\n' "$DIALOG" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Env contract
# ---------------------------------------------------------------------------

RESULT_FILE="${PASSTHRU_OVERLAY_RESULT_FILE:-}"
if [ -z "$RESULT_FILE" ]; then
  printf 'overlay.sh: PASSTHRU_OVERLAY_RESULT_FILE is required\n' >&2
  exit 2
fi

# Make sure the result dir exists, so the dialog can write without racing the
# caller. Absent-file is the cancel signal (see caller contract).
mkdir -p "$(dirname "$RESULT_FILE")" 2>/dev/null || true

TIMEOUT="${PASSTHRU_OVERLAY_TIMEOUT:-60}"

# ---------------------------------------------------------------------------
# Terminal multiplexer detection
# ---------------------------------------------------------------------------
# Order of preference: tmux -> kitty -> wezterm. Within each candidate, the
# env var must be set AND the binary must be on PATH. If the env var is set
# but the binary is missing, fall through to the next candidate rather than
# failing fast (user may have $TMUX exported from a parent shell but tmux
# itself uninstalled on this host, or a stripped-down container image).

detect_multiplexer() {
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    printf 'tmux'
    return 0
  fi
  if [ -n "${KITTY_WINDOW_ID:-}" ] && command -v kitty >/dev/null 2>&1; then
    printf 'kitty'
    return 0
  fi
  if [ -n "${WEZTERM_PANE:-}" ] && command -v wezterm >/dev/null 2>&1; then
    printf 'wezterm'
    return 0
  fi
  printf ''
  return 1
}

MUX="$(detect_multiplexer || true)"

if [ -z "$MUX" ]; then
  # Not a multiplexer-hosted terminal. Caller falls back to native dialog.
  exit 1
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
# We pass the dialog context via env vars (not argv) to keep argv free of
# untrusted tool_input content. The dialog inherits our environment, including
# PASSTHRU_OVERLAY_TOOL_NAME, PASSTHRU_OVERLAY_TOOL_INPUT_JSON,
# PASSTHRU_OVERLAY_RESULT_FILE, PASSTHRU_OVERLAY_TIMEOUT, and
# PASSTHRU_OVERLAY_TEST_ANSWER.

launch_tmux() {
  # display-popup -E: close when the inner command exits.
  # -w 80% -h 60%: large enough for the menu + rule preview, still overlay-y.
  tmux display-popup -E -w 80% -h 60% -- bash "$DIALOG"
}

launch_kitty() {
  # --type=overlay places the window in front of the current tab.
  # --no-response: do not block on kitten output.
  # kitty @ launch requires the remote-control socket ($KITTY_LISTEN_ON) or an
  # allow-remote-control config. We invoke unconditionally; failure surfaces as
  # exit 2 which the caller maps to "fall through to native dialog".
  kitty @ launch --type=overlay --no-response bash "$DIALOG"
}

launch_wezterm() {
  # split-pane creates an adjacent pane that dies when the inner command
  # exits. Good enough for a modal-ish prompt.
  wezterm cli split-pane -- bash "$DIALOG"
}

case "$MUX" in
  tmux)
    if ! launch_tmux; then
      exit 2
    fi
    ;;
  kitty)
    if ! launch_kitty; then
      exit 2
    fi
    ;;
  wezterm)
    if ! launch_wezterm; then
      exit 2
    fi
    ;;
esac

exit 0
