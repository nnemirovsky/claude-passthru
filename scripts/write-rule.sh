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
#   A lock directory at $PASSTHRU_USER_HOME/.claude/passthru.write.lock.d
#   serializes concurrent writers. mkdir is atomic on every POSIX filesystem
#   we support (Linux/macOS local + NFS), works without flock(1) on the path,
#   and fails predictably under contention. 5s timeout, released via trap EXIT.

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
# Lock acquisition (mkdir-only)
# ---------------------------------------------------------------------------
# The lock lives under the user scope even for project writes, because that's
# the "one true place" across concurrent projects for a single user.
# We use mkdir exclusively: it is atomic on every POSIX filesystem we care
# about, works without flock(1), and gives predictable behaviour under
# contention with no need for two parallel code paths.
USER_CLAUDE_DIR="${PASSTHRU_USER_HOME:-$HOME}/.claude"
mkdir -p "$USER_CLAUDE_DIR"
LOCK_DIR="$USER_CLAUDE_DIR/passthru.write.lock.d"
LOCK_TIMEOUT="${PASSTHRU_WRITE_LOCK_TIMEOUT:-5}"

LOCK_HELD=0

acquire_lock() {
  local deadline
  deadline=$(( $(date +%s) + LOCK_TIMEOUT ))
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.1
  done
}

release_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
}

if ! acquire_lock; then
  printf 'write-rule.sh: failed to acquire lock %s within %ss\n' "$LOCK_DIR" "$LOCK_TIMEOUT" >&2
  exit 1
fi

# All subsequent cleanup runs via trap, covering early exits.
BACKUP=""
# STATE machine for the atomic-write protocol:
#   NONE      no backup in play; nothing to restore.
#   BACKED_UP backup taken but TARGET not yet mutated. Cleanup just drops
#             BACKUP; TARGET is untouched.
#   WRITING   mv TMPOUT TARGET has completed; TARGET now holds unverified
#             content. Cleanup MUST restore BACKUP over TARGET before
#             dropping it, otherwise a signal here leaves corrupted content
#             on disk with no restore path (breaking the atomic guarantee).
#   VERIFIED  verifier passed OR we finished the rollback branch ourselves.
#             Cleanup only drops any leftover backup and exits.
STATE="NONE"

cleanup() {
  local rc=$?
  # Order matters: restore before releasing the lock so a concurrent writer
  # waiting on the lock never sees the half-written file.
  if [ "$STATE" = "WRITING" ] && [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    # Signal (or unexpected error) hit between `mv TMPOUT TARGET` and the
    # verifier rollback branch. Roll TARGET back to the backup.
    mv "$BACKUP" "$TARGET" 2>/dev/null || true
    BACKUP=""
  fi
  release_lock
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    rm -f "$BACKUP" 2>/dev/null || true
  fi
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

# Create BACKUP in the same directory as TARGET so the eventual `mv BACKUP
# TARGET` rollback is truly atomic (rename(2) is only atomic within a single
# filesystem; `mktemp -t` falls back to the system temp dir, which on many
# setups is a different volume -- tmpfs on Linux, /var/folders/... vs an
# external $HOME on macOS). Placing it next to TARGET guarantees rename-level
# atomicity and avoids the silent copy+unlink degradation.
BACKUP="$(mktemp "${TARGET}.backup.XXXXXX")"
cp -p "$TARGET" "$BACKUP"
STATE="BACKED_UP"

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

# Write atomically via mv-over. After this `mv`, TARGET holds unverified
# content; the cleanup trap uses STATE to roll back on signal-based exits.
# TMPOUT must live next to TARGET for the rename to be a true atomic
# same-filesystem operation (see the BACKUP placement note above).
TMPOUT="$(mktemp "${TARGET}.tmp.XXXXXX")"
printf '%s\n' "$NEW_CONTENT" > "$TMPOUT"
STATE="WRITING"
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
  STATE="VERIFIED"
  printf 'write-rule.sh: verifier rejected new rule; rolled back\n' >&2
  if [ -n "$VERIFY_ERR" ]; then
    printf '%s\n' "$VERIFY_ERR" >&2
  fi
  exit 1
fi

# Success: drop backup.
STATE="VERIFIED"
rm -f "$BACKUP"
BACKUP=""
exit 0
