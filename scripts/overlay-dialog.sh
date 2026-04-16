#!/usr/bin/env bash
# claude-passthru overlay dialog (TUI body).
#
# Runs INSIDE the popup spawned by scripts/overlay.sh. Reads tool_name and
# tool_input (as compact JSON) from env vars, renders a Y/A/N/D/Esc menu,
# optionally walks the user through a "accept or edit" regex proposal on the
# always-variants, and writes its verdict to $PASSTHRU_OVERLAY_RESULT_FILE.
#
# Env contract (exported by overlay.sh / caller):
#   PASSTHRU_OVERLAY_TOOL_NAME          the tool being gated.
#   PASSTHRU_OVERLAY_TOOL_INPUT_JSON    the tool_input payload as JSON.
#   PASSTHRU_OVERLAY_RESULT_FILE        absolute path the dialog writes to.
#   PASSTHRU_OVERLAY_TIMEOUT            seconds (default 60).
#   PASSTHRU_OVERLAY_TEST_ANSWER        test-only short-circuit. Accepted
#                                       values mirror the verdicts:
#                                         yes_once | yes_always | no_once |
#                                         no_always | cancel
#
# Output (result file format):
#   Verdict on line 1. For always-variants, rule JSON on line 2.
#     yes_once
#     yes_always
#     {"tool":"Bash","match":{"command":"^gh "}}
#     no_once
#     no_always
#     {"tool":"Bash","match":{"command":"^rm "}}
#
#   "cancel" is signaled by NOT writing the file at all. The caller treats
#   an absent or empty result file as "user bailed, fall through to native".
#
# Exit codes:
#   0 always. The caller uses the result file presence + content, not the exit
#   code, to drive its decision. Failing open keeps popup bugs from blocking
#   tool calls.

set -u

# ---------------------------------------------------------------------------
# Locate sibling propose-rule script
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/overlay-propose-rule.sh" ]; then
  _PASSTHRU_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  _PASSTHRU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_PLUGIN_ROOT="$(cd "${_PASSTHRU_SCRIPT_DIR}/.." && pwd)"
fi
PROPOSER="${_PASSTHRU_PLUGIN_ROOT}/scripts/overlay-propose-rule.sh"

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
TOOL_NAME="${PASSTHRU_OVERLAY_TOOL_NAME:-}"
TOOL_INPUT_JSON="${PASSTHRU_OVERLAY_TOOL_INPUT_JSON:-}"
RESULT_FILE="${PASSTHRU_OVERLAY_RESULT_FILE:-}"
TIMEOUT="${PASSTHRU_OVERLAY_TIMEOUT:-60}"
TEST_ANSWER="${PASSTHRU_OVERLAY_TEST_ANSWER:-}"

# Without a result file path we have nowhere to write. Bail silently (caller
# treats absence as cancel).
if [ -z "$RESULT_FILE" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

write_verdict_once() {
  # $1 = yes_once | no_once
  printf '%s\n' "$1" > "$RESULT_FILE" 2>/dev/null || true
}

write_verdict_always() {
  # $1 = yes_always | no_always
  # $2 = proposed rule JSON (one line, compact)
  {
    printf '%s\n' "$1"
    printf '%s\n' "$2"
  } > "$RESULT_FILE" 2>/dev/null || true
}

propose_rule() {
  # Invoke the proposer. On failure, emit a minimal fallback rule shape so
  # always-variants still have something to write.
  local proposed=""
  if [ -f "$PROPOSER" ]; then
    proposed="$(bash "$PROPOSER" "$TOOL_NAME" "$TOOL_INPUT_JSON" 2>/dev/null || true)"
  fi
  if [ -z "$proposed" ]; then
    proposed="$(printf '{"tool":"^%s$"}' "${TOOL_NAME:-Unknown}")"
  fi
  printf '%s' "$proposed"
}

render_menu() {
  # Best-effort preview. Truncate tool_input display for sanity.
  local preview=""
  if [ -n "$TOOL_INPUT_JSON" ]; then
    preview="$TOOL_INPUT_JSON"
    # Max display width for tool_input in the overlay menu.
    local max_preview=120
    local truncated_len=$((max_preview - 3))  # room for "..."
    if [ "${#preview}" -gt "$max_preview" ]; then
      preview="${preview:0:$truncated_len}..."
    fi
  fi
  cat <<MENU
Passthru Permission Prompt

Tool:  ${TOOL_NAME:-(unknown)}
Input: ${preview}

[Y] Yes, once
[A] Yes, always (with custom rule)
[N] No, once
[D] No, always (deny rule)
[Esc] Skip (use native dialog)
MENU
}

# ---------------------------------------------------------------------------
# Test short-circuit path
# ---------------------------------------------------------------------------
# Bats cannot realistically drive an interactive popup. PASSTHRU_OVERLAY_TEST_ANSWER
# bypasses the render + read loop and acts on the answer directly. This is the
# only way the overlay flow is exercised in the test suite; production invocations
# leave the var unset and hit the interactive path below.

if [ -n "$TEST_ANSWER" ]; then
  case "$TEST_ANSWER" in
    yes_once)
      write_verdict_once "yes_once"
      ;;
    no_once)
      write_verdict_once "no_once"
      ;;
    yes_always)
      proposed="$(propose_rule)"
      write_verdict_always "yes_always" "$proposed"
      ;;
    no_always)
      proposed="$(propose_rule)"
      write_verdict_always "no_always" "$proposed"
      ;;
    cancel)
      # Deliberately do NOT write. Caller treats missing file as cancel.
      :
      ;;
    *)
      # Unknown value. Treat as cancel.
      :
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Interactive path
# ---------------------------------------------------------------------------
# Pure-bash keypress loop. No dependency on whiptail/dialog. Single keystroke
# read with a timeout; Esc / Ctrl-C / timeout all fall through to the
# "do not write, let caller treat as cancel" branch.

render_menu

answer=""
# `read -r -s -n 1` captures a single keystroke without echo. -t gives timeout.
if ! IFS= read -r -s -n 1 -t "$TIMEOUT" key; then
  # Timeout or read error. Fall through as cancel.
  exit 0
fi

# Normalize to lowercase for comparison.
key_lc="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"

case "$key_lc" in
  y)
    answer="yes_once"
    ;;
  a)
    answer="yes_always"
    ;;
  n)
    answer="no_once"
    ;;
  d)
    answer="no_always"
    ;;
  $'\e'|"")
    # Esc (or empty result -> cancel).
    exit 0
    ;;
  *)
    # Unrecognized key: treat as cancel.
    exit 0
    ;;
esac

# Once-variants: write and done.
case "$answer" in
  yes_once|no_once)
    write_verdict_once "$answer"
    exit 0
    ;;
esac

# Always-variants: show the proposed regex, allow edit-before-write.
proposed="$(propose_rule)"

cat <<RULE

Suggested rule:
  ${proposed}

[Enter] Accept
[E] Edit
[Esc] Back
RULE

# Confirm-or-edit loop.
confirm_key=""
if ! IFS= read -r -s -n 1 -t "$TIMEOUT" confirm_key; then
  exit 0
fi
confirm_lc="$(printf '%s' "$confirm_key" | tr '[:upper:]' '[:lower:]')"

case "$confirm_lc" in
  ""|$'\n')
    # Enter: accept.
    write_verdict_always "$answer" "$proposed"
    ;;
  e)
    # Edit path. Read a full line with -e so readline handles cursor motion.
    # Validate edited JSON before committing; invalid input falls back to
    # the proposed rule so the user is not silently downgraded.
    printf 'Edit rule JSON (leave blank to accept): '
    edited=""
    if ! IFS= read -r -e -t "$TIMEOUT" edited; then
      exit 0
    fi
    if [ -z "$edited" ]; then
      write_verdict_always "$answer" "$proposed"
    elif jq -e 'type == "object"' >/dev/null 2>&1 <<<"$edited"; then
      # Require a JSON object specifically. Bare strings/numbers/arrays are
      # valid JSON but not valid rule shapes, and write-rule.sh would reject
      # them with a less helpful error.
      write_verdict_always "$answer" "$edited"
    else
      printf 'Invalid JSON (must be an object); falling back to suggested rule:\n  %s\n' "$proposed"
      write_verdict_always "$answer" "$proposed"
    fi
    ;;
  $'\e')
    # Back / cancel.
    exit 0
    ;;
  *)
    # Any other key -> treat as cancel.
    exit 0
    ;;
esac

exit 0
