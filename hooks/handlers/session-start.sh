#!/usr/bin/env bash
# claude-passthru SessionStart hook handler.
#
# Purpose:
#   One-time, best-effort hint nudging brand-new passthru users to run
#   `/passthru:bootstrap` if they already have native permission rules in
#   their `~/.claude/settings.json` that could be imported. Prints a
#   single-line plain-text message on stdout, which Claude Code surfaces
#   in the session header as "SessionStart:startup says: <text>". Then
#   touches a marker so the hint does not fire again.
#
# Contract:
#   stdin  - JSON envelope from Claude Code (SessionStart hook). We do
#            not need any of its fields; we still drain stdin defensively
#            so the writer does not hit SIGPIPE.
#   stdout - a single line of plain text when the hint should fire,
#            otherwise EMPTY. Per Claude Code docs, SessionStart stdout
#            is appended to the session view as
#            "SessionStart:startup says: <text>". Anything else (e.g.
#            `{}`) would appear verbatim to the user.
#   exit   - always 0. Any error fails open (empty stdout, exit 0).
#
# Gating:
#   - If the marker file `${PASSTHRU_USER_HOME}/.claude/passthru.bootstrap-hint-shown`
#     already exists, exit silently.
#   - If the user already has a `passthru.json` or `passthru.imported.json`
#     in either scope, they are already using the plugin - touch the
#     marker and exit silently.
#   - If `~/.claude/settings.json` has no `.permissions.allow` entries,
#     there is nothing to import - touch the marker and exit silently.
#   - Otherwise: count the allow entries, emit the hint on stdout, touch
#     the marker.
#
# Paths honor PASSTHRU_USER_HOME and PASSTHRU_PROJECT_DIR so bats tests
# never touch the real ~/.claude.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate and source common.sh (same pattern as pre/post handlers)
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh"
else
  _PASSTHRU_HANDLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_COMMON="${_PASSTHRU_HANDLER_DIR}/../common.sh"
  if [ ! -f "$_PASSTHRU_COMMON" ]; then
    # Never block session start, even on a broken install.
    exit 0
  fi
  # shellcheck disable=SC1090
  source "$_PASSTHRU_COMMON"
fi

# ---------------------------------------------------------------------------
# Fail-open wrapper: any unexpected error prints nothing + exit 0.
# ---------------------------------------------------------------------------
trap 'printf "[passthru] unexpected error in session-start.sh\n" >&2; exit 0' ERR

# ---------------------------------------------------------------------------
# Drain stdin defensively so the parent does not see SIGPIPE on its
# write end. We do not use the payload; SessionStart fields are not needed
# for this one-time hint.
# ---------------------------------------------------------------------------
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

USER_HOME="$(passthru_user_home)"
MARKER="${USER_HOME}/.claude/passthru.bootstrap-hint-shown"

# ---------------------------------------------------------------------------
# 1. Marker already set -> silent no-op.
# ---------------------------------------------------------------------------
if [ -e "$MARKER" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Ensure the parent directory for the marker exists. If we cannot create
# it, fail open - we will try again next session, and the hint is purely
# optional.
# ---------------------------------------------------------------------------
MARKER_DIR="$(dirname "$MARKER")"
if [ ! -d "$MARKER_DIR" ]; then
  mkdir -p "$MARKER_DIR" 2>/dev/null || {
    exit 0
  }
fi

# touch_marker: best-effort touch. Never aborts the script on failure.
touch_marker() {
  touch "$MARKER" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. User already uses passthru (any rule file exists) -> touch and exit.
# ---------------------------------------------------------------------------
USER_AUTHORED="$(passthru_user_authored_path)"
USER_IMPORTED="$(passthru_user_imported_path)"
PROJECT_AUTHORED="$(passthru_project_authored_path)"
PROJECT_IMPORTED="$(passthru_project_imported_path)"

if [ -f "$USER_AUTHORED" ] || [ -f "$USER_IMPORTED" ] \
   || [ -f "$PROJECT_AUTHORED" ] || [ -f "$PROJECT_IMPORTED" ]; then
  touch_marker
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Count importable entries in ~/.claude/settings.json.
#    Missing file or malformed JSON -> zero entries (and we still touch
#    the marker so we do not keep probing a broken file on every session).
# ---------------------------------------------------------------------------
SETTINGS="${USER_HOME}/.claude/settings.json"
COUNT=0

if [ -f "$SETTINGS" ]; then
  # jq returns null on missing .permissions.allow; coerce to 0.
  COUNT_OUT="$(jq -r '(.permissions.allow // []) | length' "$SETTINGS" 2>/dev/null || echo 0)"
  # Guard against empty / non-numeric output.
  case "$COUNT_OUT" in
    ''|*[!0-9]*) COUNT=0 ;;
    *) COUNT="$COUNT_OUT" ;;
  esac
fi

if [ "$COUNT" -eq 0 ]; then
  touch_marker
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Emit the one-time hint on stdout and persist the marker.
#    Single line keeps the session header readable.
# ---------------------------------------------------------------------------
printf 'passthru: detected %s importable permission rule(s) in ~/.claude/settings.json. Run /passthru:bootstrap to convert them. This tip only shows once.\n' "$COUNT"

touch_marker
exit 0
