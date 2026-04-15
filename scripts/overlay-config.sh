#!/usr/bin/env bash
# claude-passthru overlay toggle.
#
# Flips the overlay sentinel ~/.claude/passthru.overlay.disabled on or off and
# reports status. Exists as a dedicated script (rather than another flag on
# scripts/log.sh) so the UX is unambiguous: overlay is a separate subsystem
# from the audit log.
#
# Sentinel semantics:
#   absent  - overlay is enabled (default). The PreToolUse hook will launch
#             the overlay popup for ask rules + passthrough tool calls when a
#             supported multiplexer is present.
#   present - overlay is disabled. The hook falls back to emitting
#             permissionDecision: "ask" so Claude Code's native permission
#             dialog takes over.
#
# All paths honor PASSTHRU_USER_HOME so bats tests never touch real
# ~/.claude.
#
# Flags (mutually exclusive, exactly one required):
#   --enable       remove sentinel, print confirmation, exit 0
#   --disable      create sentinel, print confirmation, exit 0
#   --status       report enabled/disabled + multiplexer detection, exit 0
#   --help|-h      short usage, exit 0
#
# Anything else (no flag, unknown flag, two exclusive flags) -> usage to
# stderr, exit 2.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate and source common.sh for passthru_user_home + overlay helpers.
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh"
else
  _PASSTHRU_OVCFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_COMMON="${_PASSTHRU_OVCFG_DIR}/../hooks/common.sh"
  if [ ! -f "$_PASSTHRU_COMMON" ]; then
    printf 'overlay-config.sh: cannot locate hooks/common.sh (tried CLAUDE_PLUGIN_ROOT and %s)\n' \
      "$_PASSTHRU_COMMON" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$_PASSTHRU_COMMON"
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: overlay-config.sh <action>

Toggle the claude-passthru permission-prompt overlay on or off, or report
its current state plus multiplexer detection.

Actions (exactly one required):
  --enable     remove the opt-out sentinel (overlay ON)
  --disable    create the opt-out sentinel (overlay OFF)
  --status     print enabled/disabled plus multiplexer detection
  --help, -h   this help

Sentinel path: ~/.claude/passthru.overlay.disabled (honors
PASSTHRU_USER_HOME). Absent means enabled, present means disabled.

Examples:
  overlay-config.sh --enable
  overlay-config.sh --disable
  overlay-config.sh --status
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ACTION=""

set_action() {
  local new="$1"
  if [ -n "$ACTION" ] && [ "$ACTION" != "$new" ]; then
    printf '[passthru overlay] %s and %s are mutually exclusive\n' \
      "--${ACTION}" "--${new}" >&2
    printf '\n' >&2
    usage >&2
    exit 2
  fi
  ACTION="$new"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --enable)
      set_action enable
      shift
      ;;
    --disable)
      set_action disable
      shift
      ;;
    --status)
      set_action status
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      printf '[passthru overlay] unknown argument: %s\n' "$1" >&2
      printf '\n' >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$ACTION" ]; then
  printf '[passthru overlay] no action given (expected --enable, --disable, or --status)\n' >&2
  printf '\n' >&2
  usage >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SENT_PATH="$(passthru_user_home)/.claude/passthru.overlay.disabled"

# ---------------------------------------------------------------------------
# Multiplexer detection summary (used by --status)
# ---------------------------------------------------------------------------

# report_multiplexer_line: prints a single human-readable line describing
# which multiplexer env var is set and whether its binary is on PATH. If
# nothing is announced via env vars, prints a "none detected" line.
report_multiplexer_line() {
  # Exactly one of the three is reported, in the same preference order used
  # by detect_overlay_multiplexer in common.sh (tmux -> kitty -> wezterm).
  # If none of the env vars are set, we still emit a single line so the
  # --status output is always stable.
  local name=""
  local envvar=""

  if [ -n "${TMUX:-}" ]; then
    name="tmux"
    envvar="TMUX"
  elif [ -n "${KITTY_WINDOW_ID:-}" ]; then
    name="kitty"
    envvar="KITTY_WINDOW_ID"
  elif [ -n "${WEZTERM_PANE:-}" ]; then
    name="wezterm"
    envvar="WEZTERM_PANE"
  fi

  if [ -z "$name" ]; then
    printf 'multiplexer: none detected (no TMUX / KITTY_WINDOW_ID / WEZTERM_PANE in env)\n'
    return 0
  fi

  if command -v "$name" >/dev/null 2>&1; then
    printf 'multiplexer: detected: %s (env %s set, binary on PATH)\n' "$name" "$envvar"
  else
    printf 'multiplexer: detected: %s (binary missing, env %s set but %s not on PATH)\n' \
      "$name" "$envvar" "$name"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$ACTION" in
  enable)
    # Idempotent: removing a missing file is a no-op.
    rm -f "$SENT_PATH"
    printf 'overlay enabled\n'
    printf 'sentinel: %s (absent)\n' "$SENT_PATH"
    exit 0
    ;;
  disable)
    mkdir -p "$(dirname "$SENT_PATH")" 2>/dev/null || true
    : > "$SENT_PATH"
    printf 'overlay disabled\n'
    printf 'sentinel: %s (present)\n' "$SENT_PATH"
    exit 0
    ;;
  status)
    if [ -e "$SENT_PATH" ]; then
      printf 'overlay: disabled\n'
    else
      printf 'overlay: enabled\n'
    fi
    printf 'sentinel: %s\n' "$SENT_PATH"
    report_multiplexer_line
    exit 0
    ;;
esac
