#!/usr/bin/env bash
# claude-passthru PostToolUseFailure hook handler.
#
# Purpose:
#   Claude Code routes FAILED tool calls (non-zero outcome, including
#   permission refusals and runtime errors) to PostToolUseFailure rather than
#   PostToolUse. Without this handler, a `passthrough` decision from
#   pre-tool-use.sh that ends in failure leaves an orphan breadcrumb in
#   $TMPDIR and never produces an `asked_*` audit line, so the audit log
#   shows an incomplete picture. This handler mirrors post-tool-use.sh's
#   classification path using the shared classify_passthrough_outcome helper
#   in common.sh, with two distinctions:
#
#     1. The failure envelope carries `error` / `error_type` /
#        `is_interrupt` / `is_timeout` fields instead of `tool_response`.
#        We inspect `error` (and, when absent, the interrupt/timeout flags)
#        to decide whether the call was permission-denied or a generic
#        runtime error.
#
#     2. Non-permission failures are logged as a new `errored` event with
#        the `error_type` field preserved, so users can distinguish a
#        real tool error from a permission refusal in /passthru:log.
#
# Contract:
#   stdin  - JSON payload from Claude Code with at least:
#              { "tool_name": "...", "tool_input": {...},
#                "tool_use_id": "...", "error": "...",
#                "error_type": "...", "is_interrupt": bool,
#                "is_timeout": bool }
#   stdout - { "continue": true } always. PostToolUseFailure runs after the
#            tool has already failed; our output never alters that outcome.
#   exit   - always 0. Audit failures must never block anything.
#
# Disabled mode:
#   If ~/.claude/passthru.audit.enabled does not exist (sentinel), emit
#   {"continue": true} and exit 0 immediately after self-healing any orphan
#   breadcrumb. Zero-cost when audit is off.
#
# Breadcrumb:
#   $TMPDIR/passthru-pre-<tool_use_id>.json written by pre-tool-use.sh on
#   passthrough. If missing, we either logged the decision PreToolUse side
#   or audit was off then. Either way, no-op.
#
# Paths honor PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR / TMPDIR so bats
# tests never touch real ~/.claude or /tmp.

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
    printf '[passthru] fatal: cannot locate common.sh (tried $CLAUDE_PLUGIN_ROOT and %s)\n' \
      "$_PASSTHRU_COMMON" >&2
    printf '{"continue": true}\n'
    exit 0
  fi
  # shellcheck disable=SC1090
  source "$_PASSTHRU_COMMON"
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
trap 'printf "[passthru] unexpected error in post-tool-use-failure.sh\n" >&2; emit_passthrough; exit 0' ERR

# --- 1. Audit sentinel + self-heal ----------------------------------------
# When disabled, we still self-heal the breadcrumb left over by PreToolUse so
# orphans do not accumulate in $TMPDIR if the user toggles audit off mid-flight.
if ! audit_enabled; then
  if [ ! -t 0 ]; then
    DRAIN_INPUT="$(cat || true)"
  else
    DRAIN_INPUT=""
  fi
  if [ -n "$DRAIN_INPUT" ] && jq -e '.' >/dev/null 2>&1 <<<"$DRAIN_INPUT"; then
    DRAIN_TUID="$(jq -r '.tool_use_id // ""' <<<"$DRAIN_INPUT" 2>/dev/null || true)"
    DRAIN_SAFE_TUID="$(sanitize_tool_use_id "$DRAIN_TUID")"
    if [ -n "$DRAIN_SAFE_TUID" ]; then
      DRAIN_PATH="$(passthru_tmpdir)/passthru-pre-${DRAIN_SAFE_TUID}.json"
      [ -f "$DRAIN_PATH" ] && rm -f "$DRAIN_PATH" 2>/dev/null || true
    fi
  fi
  emit_passthrough
  exit 0
fi

# --- 2. Read stdin --------------------------------------------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(cat || true)"
fi
if [ -z "$INPUT" ]; then
  emit_passthrough
  exit 0
fi
if ! jq -e '.' >/dev/null 2>&1 <<<"$INPUT"; then
  printf '[passthru] warning: post-tool-use-failure malformed stdin JSON; skipping\n' >&2
  emit_passthrough
  exit 0
fi

TOOL_NAME="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null || true)"
TOOL_INPUT="$(jq -c '.tool_input // {}' <<<"$INPUT" 2>/dev/null || echo '{}')"
TOOL_USE_ID="$(jq -r '.tool_use_id // ""' <<<"$INPUT" 2>/dev/null || true)"
ERROR_MSG="$(jq -r '.error // ""' <<<"$INPUT" 2>/dev/null || echo '')"
ERROR_TYPE="$(jq -r '.error_type // ""' <<<"$INPUT" 2>/dev/null || echo '')"
IS_INTERRUPT="$(jq -r '.is_interrupt // false' <<<"$INPUT" 2>/dev/null || echo 'false')"
IS_TIMEOUT="$(jq -r '.is_timeout // false' <<<"$INPUT" 2>/dev/null || echo 'false')"

# --- 3. Locate breadcrumb -------------------------------------------------
if [ -z "$TOOL_USE_ID" ]; then
  emit_passthrough
  exit 0
fi

SAFE_TOOL_USE_ID="$(sanitize_tool_use_id "$TOOL_USE_ID")"
if [ -z "$SAFE_TOOL_USE_ID" ]; then
  emit_passthrough
  exit 0
fi

CRUMB_PATH="$(passthru_tmpdir)/passthru-pre-${SAFE_TOOL_USE_ID}.json"
if [ ! -f "$CRUMB_PATH" ]; then
  # No breadcrumb means PreToolUse decided allow/deny itself (or audit was
  # off then). Silent no-op.
  emit_passthrough
  exit 0
fi

# Always unlink the breadcrumb, success or failure.
# shellcheck disable=SC2064
trap "rm -f '$CRUMB_PATH' 2>/dev/null || true" EXIT

# --- 4. Read breadcrumb ---------------------------------------------------
CRUMB_RAW="$(cat "$CRUMB_PATH" 2>/dev/null || true)"
if [ -z "$CRUMB_RAW" ] || ! jq -e '.' >/dev/null 2>&1 <<<"$CRUMB_RAW"; then
  printf '[passthru] warning: malformed breadcrumb %s; unlinking without log\n' \
    "$CRUMB_PATH" >&2
  emit_passthrough
  exit 0
fi

OLD_USER_SHA="$(jq -r '.settings_sha_user // ""' <<<"$CRUMB_RAW" 2>/dev/null || echo '')"
OLD_PROJ_SHA="$(jq -r '.settings_sha_project // ""' <<<"$CRUMB_RAW" 2>/dev/null || echo '')"

# --- 5. Classify: permission-denied vs generic error ---------------------
# Decision tree:
#   - If ERROR_MSG matches the permission-denied token set (same set as
#     is_denied_response), classify via shared helper as asked_denied_*.
#   - Else if is_interrupt is true, log `errored` with error_type=interrupted.
#   - Else if is_timeout is true, log `errored` with error_type=timeout.
#   - Else log `errored` with whatever error_type CC provided (may be empty).
if is_permission_error_string "$ERROR_MSG"; then
  EVENT="$(classify_passthrough_outcome "1" "$TOOL_NAME" "$TOOL_INPUT" "$OLD_USER_SHA" "$OLD_PROJ_SHA")"
  write_post_event "$EVENT" "$TOOL_NAME" "$TOOL_USE_ID"
else
  # Non-permission failure. Synthesize an error_type so the log line is
  # informative even when CC omits the field.
  EFFECTIVE_TYPE="$ERROR_TYPE"
  if [ -z "$EFFECTIVE_TYPE" ]; then
    if [ "$IS_INTERRUPT" = "true" ]; then
      EFFECTIVE_TYPE="interrupted"
    elif [ "$IS_TIMEOUT" = "true" ]; then
      EFFECTIVE_TYPE="timeout"
    fi
  fi
  write_post_event "errored" "$TOOL_NAME" "$TOOL_USE_ID" "$EFFECTIVE_TYPE"
fi

emit_passthrough
exit 0
