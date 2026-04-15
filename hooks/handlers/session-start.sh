#!/usr/bin/env bash
# claude-passthru SessionStart hook handler.
#
# Purpose:
#   Nudges passthru users to run `/passthru:bootstrap` whenever their native
#   `permissions.allow` entries (in settings.json / settings.local.json) are
#   not yet fully reflected in `passthru.imported.json`. The hint re-fires
#   every session until migration is complete and then auto-silences.
#   Emits `{"systemMessage":"<text>"}` on stdout (Claude Code surfaces this
#   as `SessionStart:startup says: <text>` in the session view).
#
# Contract:
#   stdin  - JSON envelope from Claude Code (SessionStart hook). We do
#            not need any of its fields, and `exec < /dev/null` up front
#            ensures nothing downstream ever blocks on reading it.
#   stdout - a single-line JSON object `{"systemMessage":"<text>"}` when
#            the hint should fire, otherwise EMPTY. Plain text stdout
#            does NOT surface - the JSON envelope is the correct contract.
#   exit   - always 0. Any error fails open (empty stdout, exit 0).
#
# Gating (hash-diff):
#   1. Compute `settings_importable_hashes` - a set over every importable
#      entry across user + project settings files (filtered by
#      `is_importable_entry`, the same predicate bootstrap.sh uses).
#   2. Compute `imported_hashes` - every `_source_hash` present in either
#      passthru.imported.json file. Rules without `_source_hash` contribute
#      nothing; legacy imported files pre-dating this change therefore
#      force the hint to re-fire until bootstrap is re-run, which rewrites
#      the files with hashes.
#   3. If `settings - imported` is non-empty, emit the hint with the
#      missing count. Otherwise stay silent.
#
# The old marker file (`~/.claude/passthru.bootstrap-hint-shown`) is no
# longer consulted or written. The hash diff is authoritative.
#
# Paths honor PASSTHRU_USER_HOME and PASSTHRU_PROJECT_DIR so bats tests
# never touch the real ~/.claude.

set -euo pipefail

# ---------------------------------------------------------------------------
# Redirect stdin to /dev/null before sourcing common.sh or running any
# command that might read from it. SessionStart never needs stdin contents,
# and on macOS Claude Code can keep the pipe open across `claude --resume`
# which would hang any cat/read call. This mirrors the pattern used by
# memsearch's session-start.sh.
# ---------------------------------------------------------------------------
exec < /dev/null

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
# 1. Collect the importable-entry hash set and the already-imported hash set.
#    Sort + uniq for set semantics.
# ---------------------------------------------------------------------------
SETTINGS_HASHES="$(settings_importable_hashes | sort -u)"
IMPORTED_HASHES="$(imported_hashes | sort -u)"

# ---------------------------------------------------------------------------
# 2. Diff: settings - imported. Anything left is un-imported.
#    Use `comm -23` to print lines only in the first (settings) side.
# ---------------------------------------------------------------------------
MISSING_COUNT=0
if [ -n "$SETTINGS_HASHES" ]; then
  # comm needs seekable inputs via process substitution.
  MISSING="$(comm -23 \
    <(printf '%s\n' "$SETTINGS_HASHES") \
    <(printf '%s\n' "$IMPORTED_HASHES"))"
  if [ -n "$MISSING" ]; then
    # Count non-empty lines.
    MISSING_COUNT="$(printf '%s\n' "$MISSING" | grep -c '.' || true)"
  fi
fi

if [ "$MISSING_COUNT" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Emit the hint on stdout as a JSON `systemMessage` envelope.
#    Singular/plural: "1 importable rule" vs "N importable rules".
# ---------------------------------------------------------------------------
if [ "$MISSING_COUNT" -eq 1 ]; then
  HINT_MSG="passthru: 1 importable permission rule in settings not yet imported. Run /passthru:bootstrap to convert it."
else
  HINT_MSG="passthru: ${MISSING_COUNT} importable permission rules in settings not yet imported. Run /passthru:bootstrap to convert them."
fi

# jq -nc builds a compact JSON object with proper escaping. Fail-open: if
# jq cannot produce output, we stay silent rather than emit broken JSON.
if ENVELOPE="$(jq -nc --arg msg "$HINT_MSG" '{systemMessage:$msg}' 2>/dev/null)"; then
  printf '%s\n' "$ENVELOPE"
fi

exit 0
