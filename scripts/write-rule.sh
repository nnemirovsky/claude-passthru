#!/usr/bin/env bash
# claude-passthru atomic rule write wrapper.
#
# Usage:
#   write-rule.sh <scope> <list> <rule_json>
#   scope = user|project
#   list  = allow|deny
#
# Behaviour:
#   1. Resolve target passthru.json path (honors PASSTHRU_USER_HOME +
#      PASSTHRU_PROJECT_DIR). Create it if missing with
#      {"version":1,"allow":[],"deny":[]}.
#   2. Take a backup of the current file (if any) to a temp file.
#   3. Append <rule_json> to the chosen list via jq (pure JSON manipulation).
#   4. Run scripts/verify.sh --quiet to validate the new file alongside the
#      other scope files.
#   5. On verifier failure: restore backup atomically (mv over target), print
#      verifier's error on stderr, exit non-zero.
#   6. On success: delete the backup, exit 0.
#
# Concurrency:
#   A lock file at $PASSTHRU_USER_HOME/.claude/passthru.write.lock serializes
#   concurrent writes. Uses flock(1) when available, otherwise a mkdir-based
#   fallback (mkdir is atomic on POSIX filesystems). 5s timeout. Released via
#   trap EXIT.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate scripts + common.sh
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh" ]; then
  _PASSTHRU_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  _PASSTHRU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_PLUGIN_ROOT="$(cd "${_PASSTHRU_SCRIPT_DIR}/.." && pwd)"
fi

# shellcheck disable=SC1091
source "${_PASSTHRU_PLUGIN_ROOT}/hooks/common.sh"

VERIFY_SH="${_PASSTHRU_PLUGIN_ROOT}/scripts/verify.sh"
if [ ! -x "$VERIFY_SH" ] && [ ! -f "$VERIFY_SH" ]; then
  printf 'write-rule.sh: cannot locate scripts/verify.sh (looked in %s)\n' "$VERIFY_SH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

if [ $# -ne 3 ]; then
  cat <<USAGE >&2
usage: write-rule.sh <scope> <list> <rule_json>
  scope = user|project
  list  = allow|deny
  rule_json = a JSON object
USAGE
  exit 1
fi

SCOPE="$1"
LIST="$2"
RULE_JSON="$3"

case "$SCOPE" in
  user|project) ;;
  *) printf 'write-rule.sh: invalid scope: %s (want user|project)\n' "$SCOPE" >&2; exit 1 ;;
esac

case "$LIST" in
  allow|deny) ;;
  *) printf 'write-rule.sh: invalid list: %s (want allow|deny)\n' "$LIST" >&2; exit 1 ;;
esac

# Validate the rule JSON parses as an object.
if ! jq -e 'type == "object"' <<<"$RULE_JSON" >/dev/null 2>&1; then
  printf 'write-rule.sh: rule_json must be a JSON object\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve target path
# ---------------------------------------------------------------------------

case "$SCOPE" in
  user)    TARGET="$(passthru_user_authored_path)" ;;
  project) TARGET="$(passthru_project_authored_path)" ;;
esac

TARGET_DIR="$(dirname "$TARGET")"
mkdir -p "$TARGET_DIR"

# ---------------------------------------------------------------------------
# Lock acquisition
# ---------------------------------------------------------------------------
# The lock lives under the user scope even for project writes, because that's
# the "one true place" across concurrent projects for a single user.
USER_CLAUDE_DIR="${PASSTHRU_USER_HOME:-$HOME}/.claude"
mkdir -p "$USER_CLAUDE_DIR"
LOCK_PATH="$USER_CLAUDE_DIR/passthru.write.lock"
LOCK_TIMEOUT="${PASSTHRU_WRITE_LOCK_TIMEOUT:-5}"

LOCK_FD=""
LOCK_HELD=""  # "flock" | "mkdir" | ""

acquire_lock_flock() {
  # Open fd 9 on the lockfile, block up to LOCK_TIMEOUT seconds.
  exec 9>"$LOCK_PATH"
  if flock -w "$LOCK_TIMEOUT" 9 2>/dev/null; then
    LOCK_FD=9
    LOCK_HELD="flock"
    return 0
  fi
  exec 9>&-
  return 1
}

acquire_lock_mkdir() {
  # mkdir is atomic. Spin up to LOCK_TIMEOUT seconds, sleeping 0.1s between tries.
  local lockdir="${LOCK_PATH}.d"
  local deadline
  deadline=$(( $(date +%s) + LOCK_TIMEOUT ))
  while :; do
    if mkdir "$lockdir" 2>/dev/null; then
      LOCK_HELD="mkdir"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.1
  done
}

release_lock() {
  case "$LOCK_HELD" in
    flock)
      [ -n "$LOCK_FD" ] && exec 9>&- 2>/dev/null || true
      ;;
    mkdir)
      rmdir "${LOCK_PATH}.d" 2>/dev/null || true
      ;;
  esac
  LOCK_HELD=""
}

if command -v flock >/dev/null 2>&1; then
  if ! acquire_lock_flock; then
    printf 'write-rule.sh: failed to acquire lock %s within %ss\n' "$LOCK_PATH" "$LOCK_TIMEOUT" >&2
    exit 1
  fi
else
  if ! acquire_lock_mkdir; then
    printf 'write-rule.sh: failed to acquire lock %s within %ss\n' "$LOCK_PATH" "$LOCK_TIMEOUT" >&2
    exit 1
  fi
fi

# All subsequent cleanup runs via trap, covering early exits.
BACKUP=""

cleanup() {
  local rc=$?
  release_lock
  # On error, restore backup if one exists. Covers `set -e` aborting between
  # the mv-over and the explicit `BACKUP=""` reset further down so the user
  # never sees a half-written TARGET with a wiped BACKUP.
  if [ "$rc" -ne 0 ] && [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    mv -f "$BACKUP" "$TARGET" 2>/dev/null || true
    BACKUP=""
  fi
  # Always drop stale backup on clean exit.
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] && rm -f "$BACKUP" 2>/dev/null || true
  exit $rc
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# ---------------------------------------------------------------------------
# Create target if missing; take backup of current content
# ---------------------------------------------------------------------------

if [ ! -e "$TARGET" ]; then
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$TARGET"
fi

# Verify target parses before attempting any mutation.
if ! jq -e '.' "$TARGET" >/dev/null 2>&1; then
  printf 'write-rule.sh: existing target file does not parse as JSON: %s\n' "$TARGET" >&2
  exit 1
fi

BACKUP="$(mktemp -t passthru-write.XXXXXX)"
cp -p "$TARGET" "$BACKUP"

# ---------------------------------------------------------------------------
# Append the rule
# ---------------------------------------------------------------------------

NEW_CONTENT="$(
  jq --argjson rule "$RULE_JSON" --arg list "$LIST" '
    (.version // 1) as $v
    | . as $doc
    | $doc
    | .version = $v
    | .allow = (.allow // [])
    | .deny  = (.deny // [])
    | .[$list] = (.[$list] + [$rule])
  ' "$TARGET"
)" || {
  printf 'write-rule.sh: jq failed to append rule\n' >&2
  exit 1
}

# Write atomically via mv-over.
TMPOUT="$(mktemp -t passthru-write-out.XXXXXX)"
printf '%s\n' "$NEW_CONTENT" > "$TMPOUT"
mv "$TMPOUT" "$TARGET"

# ---------------------------------------------------------------------------
# Verify the new merged state
# ---------------------------------------------------------------------------

VERIFY_ERR=""
set +e
VERIFY_ERR="$(bash "$VERIFY_SH" --quiet 2>&1 >/dev/null)"
VERIFY_RC=$?
set -e

if [ "$VERIFY_RC" -ne 0 ]; then
  # Restore backup atomically.
  mv "$BACKUP" "$TARGET"
  BACKUP=""
  printf 'write-rule.sh: verifier rejected new rule; rolled back\n' >&2
  if [ -n "$VERIFY_ERR" ]; then
    printf '%s\n' "$VERIFY_ERR" >&2
  fi
  exit 1
fi

# Success: drop backup.
rm -f "$BACKUP"
BACKUP=""
exit 0
