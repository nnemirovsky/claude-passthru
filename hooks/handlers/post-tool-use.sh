#!/usr/bin/env bash
# claude-passthru PostToolUse hook handler.
#
# Purpose:
#   When PreToolUse decides `passthrough`, the native Claude Code permission
#   dialog handles the call. PostToolUse runs after the tool completes and
#   lets us classify how the user answered that dialog (once/always/denied).
#   Output goes to ~/.claude/passthru-audit.log alongside the PreToolUse events.
#
# Contract:
#   stdin  - JSON payload from Claude Code with at least:
#              { "tool_name": "...", "tool_input": {...},
#                "tool_use_id": "...", "tool_response": {...} }
#   stdout - { "continue": true } always. PostToolUse runs after tool execution;
#            our output never affects tool outcomes.
#   exit   - always 0. Audit failures must never block anything.
#
# Disabled mode:
#   If ~/.claude/passthru.audit.enabled does not exist (sentinel), emit
#   {"continue": true} and exit 0 immediately. Zero overhead.
#
# Breadcrumb:
#   $TMPDIR/passthru-pre-<tool_use_id>.json written by pre-tool-use.sh on
#   passthrough. If missing, we either logged the decision PreToolUse side
#   or audit was disabled then. Either way, no-op.
#
# Paths honor PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR / TMPDIR so bats
# tests never touch real ~/.claude or /tmp.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate and source common.sh (same pattern as pre-tool-use.sh)
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
# Helpers (mirror pre-tool-use.sh; kept local so the two handlers stay
# independent and easy to reason about without a third shared file)
# ---------------------------------------------------------------------------

passthru_user_home() {
  printf '%s\n' "${PASSTHRU_USER_HOME:-$HOME}"
}

passthru_tmpdir() {
  printf '%s\n' "${TMPDIR:-/tmp}"
}

passthru_iso_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

passthru_sha256() {
  local path="$1"
  [ -f "$path" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  fi
}

audit_enabled() {
  local sentinel
  sentinel="$(passthru_user_home)/.claude/passthru.audit.enabled"
  [ -e "$sentinel" ]
}

audit_log_path() {
  printf '%s/.claude/passthru-audit.log\n' "$(passthru_user_home)"
}

emit_passthrough() {
  printf '{"continue": true}\n'
}

# write_post_event <event> <tool_name> <tool_use_id>
# Appends one JSONL line to the audit log. Fail-open (never propagates errors).
write_post_event() {
  local event="$1" tool="$2" tool_use_id="$3"
  local path ts line dir
  path="$(audit_log_path)"
  ts="$(passthru_iso_ts)"

  line="$(
    jq -cn \
      --arg ts "$ts" \
      --arg event "$event" \
      --arg tool "$tool" \
      --arg tool_use_id "$tool_use_id" \
      '{
        ts: $ts,
        event: $event,
        source: "native",
        tool: $tool,
        tool_use_id: (if $tool_use_id == "" then null else $tool_use_id end)
      }' 2>/dev/null
  )" || return 0
  [ -z "$line" ] && return 0

  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0

  printf '%s\n' "$line" >> "$path" 2>/dev/null || return 0
  return 0
}

# is_denied_response <tool_response_json>
# Accepts several shapes Claude Code has been observed to emit for a
# permission-denied outcome. Rather than pin to one schema, we treat any
# of the following as "denied":
#   - tool_response is literally null or the literal string "null"
#   - tool_response.permissionDenied is true
#   - tool_response.error contains a "permission" substring
#   - tool_response.interrupted / isError with a permission hint
#   - tool_response.status == "denied" or "permission_denied"
# Returns 0 when denied, 1 otherwise.
is_denied_response() {
  local resp="$1"
  [ -z "$resp" ] && return 0
  if [ "$resp" = "null" ]; then
    return 0
  fi
  # Whether the JSON's permissionDenied flag is true.
  local flag
  flag="$(jq -r '.permissionDenied // false' <<<"$resp" 2>/dev/null || echo 'false')"
  if [ "$flag" = "true" ]; then
    return 0
  fi
  # Error messages carrying a permission marker.
  local err status
  err="$(jq -r '(.error // .errorMessage // .message // "") | tostring' <<<"$resp" 2>/dev/null || echo '')"
  if printf '%s' "$err" | grep -qiE 'permission|denied|blocked|not allowed'; then
    return 0
  fi
  status="$(jq -r '.status // .state // ""' <<<"$resp" 2>/dev/null || echo '')"
  case "$status" in
    denied|permission_denied|permissionDenied|blocked)
      return 0
      ;;
  esac
  return 1
}

# entries_look_tailored <old_allow_json> <new_allow_json> <tool_name> <tool_input_json>
# Returns 0 if any entry added to new_allow (relative to old_allow) looks
# plausibly tied to the given tool call. Because we only persisted a sha in
# the breadcrumb, we use a simple heuristic against the CURRENT settings file.
#
# For the "is it plausibly tailored" check we use the current new_allow array
# in full (old is omitted here; we only snapshot the hash). Plausible match:
#   - Bash(cmd)  tool entry: the rule pattern, stripped of a trailing ":*",
#                matches a leading token of tool_input.command. Also accept
#                raw "Bash" with no argument if tool_name == Bash.
#   - WebFetch(domain:host): host equals (or is suffix of) the URL host in
#                tool_input.url.
#   - Tool name equality fallback: a bare "<ToolName>" entry matches any call
#                to that tool.
# All other entries fall through as "not tailored".
#
# $1 is IGNORED for now (we don't have the old content, only sha), but kept in
# the signature so callers can pass the pre-snapshot when we upgrade the
# breadcrumb schema in the future.
entries_look_tailored() {
  # shellcheck disable=SC2034
  local _old_allow="$1"
  local new_entries="$2" tool_name="$3" tool_input="$4"

  [ -z "$new_entries" ] && return 1
  # Iterate the new_entries array; each is a string like "Bash(ls:*)".
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    if entry_matches_call "$entry" "$tool_name" "$tool_input"; then
      return 0
    fi
  done < <(jq -r '.[]? | select(type == "string")' <<<"$new_entries" 2>/dev/null)
  return 1
}

# entry_matches_call <entry> <tool_name> <tool_input_json>
# Match a single native permissions string against the current tool call.
entry_matches_call() {
  local entry="$1" tool_name="$2" tool_input="$3"

  # Bare tool-name entry -> matches any call to that tool.
  if [ "$entry" = "$tool_name" ]; then
    return 0
  fi

  # Parse the leading "ToolName(...)" form.
  local entry_tool entry_arg
  entry_tool="${entry%%(*}"
  if [ "$entry_tool" = "$entry" ]; then
    # No parentheses; already handled by the bare-name branch.
    return 1
  fi
  if [ "$entry_tool" != "$tool_name" ]; then
    return 1
  fi
  # Strip leading "ToolName(" and trailing ")".
  entry_arg="${entry#*(}"
  entry_arg="${entry_arg%)}"

  case "$tool_name" in
    Bash)
      # Strip ":*" tail.
      local prefix="${entry_arg%:*}"
      [ -z "$prefix" ] && return 1
      # Extract the first token from the tool_input.command.
      local cmd first_tok
      cmd="$(jq -r '.command // ""' <<<"$tool_input" 2>/dev/null || echo '')"
      [ -z "$cmd" ] && return 1
      # Leading token is everything up to first whitespace.
      first_tok="${cmd%% *}"
      # prefix may itself contain a space (e.g. "gh pr"). Accept when cmd
      # starts with prefix followed by a space or end-of-string.
      case "$cmd" in
        "$prefix"|"$prefix "*) return 0 ;;
      esac
      # Also accept first-token equality so bare "Bash(ls:*)" matches "ls".
      if [ "$first_tok" = "$prefix" ]; then
        return 0
      fi
      return 1
      ;;
    WebFetch)
      local want_host
      want_host="${entry_arg#domain:}"
      [ -z "$want_host" ] && return 1
      local url host
      url="$(jq -r '.url // ""' <<<"$tool_input" 2>/dev/null || echo '')"
      [ -z "$url" ] && return 1
      host="${url#*://}"
      host="${host%%/*}"
      host="${host%%:*}"
      [ -z "$host" ] && return 1
      if [ "$host" = "$want_host" ] || [[ "$host" == *".$want_host" ]]; then
        return 0
      fi
      return 1
      ;;
    *)
      # Generic fallback: if entry_arg is a non-empty substring of the first
      # string value in tool_input, call it tailored.
      [ -z "$entry_arg" ] && return 0
      local any_val
      any_val="$(jq -r '[.. | strings] | .[0] // ""' <<<"$tool_input" 2>/dev/null || echo '')"
      case "$any_val" in
        *"$entry_arg"*) return 0 ;;
      esac
      return 1
      ;;
  esac
}

# read_settings_allow <path>: emit permissions.allow as a JSON array, or "[]".
read_settings_allow() {
  local path="$1"
  [ -f "$path" ] || { printf '[]\n'; return 0; }
  jq -c '.permissions.allow // []' "$path" 2>/dev/null || printf '[]\n'
}

read_settings_deny() {
  local path="$1"
  [ -f "$path" ] || { printf '[]\n'; return 0; }
  jq -c '.permissions.deny // []' "$path" 2>/dev/null || printf '[]\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
trap 'printf "[passthru] unexpected error in post-tool-use.sh\n" >&2; emit_passthrough; exit 0' ERR

# --- 1. Audit sentinel -----------------------------------------------------
# When disabled, zero-overhead: do not even read stdin.
if ! audit_enabled; then
  emit_passthrough
  exit 0
fi

# --- 2. Read stdin ---------------------------------------------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(cat || true)"
fi
if [ -z "$INPUT" ]; then
  # No payload to classify; nothing we can do.
  emit_passthrough
  exit 0
fi
if ! jq -e '.' >/dev/null 2>&1 <<<"$INPUT"; then
  printf '[passthru] warning: post-tool-use malformed stdin JSON; skipping\n' >&2
  emit_passthrough
  exit 0
fi

TOOL_NAME="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null || true)"
TOOL_INPUT="$(jq -c '.tool_input // {}' <<<"$INPUT" 2>/dev/null || echo '{}')"
TOOL_USE_ID="$(jq -r '.tool_use_id // ""' <<<"$INPUT" 2>/dev/null || true)"
TOOL_RESPONSE="$(jq -c '.tool_response // null' <<<"$INPUT" 2>/dev/null || echo 'null')"

# --- 3. Locate breadcrumb --------------------------------------------------
if [ -z "$TOOL_USE_ID" ]; then
  emit_passthrough
  exit 0
fi

CRUMB_PATH="$(passthru_tmpdir)/passthru-pre-${TOOL_USE_ID}.json"
if [ ! -f "$CRUMB_PATH" ]; then
  # No breadcrumb means PreToolUse decided allow/deny itself (or audit was
  # off then). Silent no-op; no log line.
  emit_passthrough
  exit 0
fi

# Always unlink the breadcrumb, success or failure.
# shellcheck disable=SC2064
trap "rm -f '$CRUMB_PATH' 2>/dev/null || true" EXIT

# --- 4. Read breadcrumb ----------------------------------------------------
CRUMB_RAW="$(cat "$CRUMB_PATH" 2>/dev/null || true)"
if [ -z "$CRUMB_RAW" ] || ! jq -e '.' >/dev/null 2>&1 <<<"$CRUMB_RAW"; then
  printf '[passthru] warning: malformed breadcrumb %s; unlinking without log\n' \
    "$CRUMB_PATH" >&2
  emit_passthrough
  exit 0
fi

OLD_USER_SHA="$(jq -r '.settings_sha_user // ""' <<<"$CRUMB_RAW" 2>/dev/null || echo '')"
OLD_PROJ_SHA="$(jq -r '.settings_sha_project // ""' <<<"$CRUMB_RAW" 2>/dev/null || echo '')"

# --- 5. Compute current shas ----------------------------------------------
USER_SETTINGS="$(passthru_user_home)/.claude/settings.json"
PROJ_SETTINGS="${PASSTHRU_PROJECT_DIR:-$PWD}/.claude/settings.local.json"
NEW_USER_SHA="$(passthru_sha256 "$USER_SETTINGS")"
NEW_PROJ_SHA="$(passthru_sha256 "$PROJ_SETTINGS")"

USER_CHANGED=0
PROJ_CHANGED=0
[ "$OLD_USER_SHA" != "$NEW_USER_SHA" ] && USER_CHANGED=1
[ "$OLD_PROJ_SHA" != "$NEW_PROJ_SHA" ] && PROJ_CHANGED=1

# --- 6. Classify outcome ---------------------------------------------------
EVENT=""
if is_denied_response "$TOOL_RESPONSE"; then
  # Default: asked_denied_once. Upgrade to asked_denied_always if a deny
  # entry tailored to this call appears in the current settings.
  EVENT="asked_denied_once"
  if [ "$USER_CHANGED" -eq 1 ] || [ "$PROJ_CHANGED" -eq 1 ]; then
    UDENY="$(read_settings_deny "$USER_SETTINGS")"
    PDENY="$(read_settings_deny "$PROJ_SETTINGS")"
    if entries_look_tailored "[]" "$UDENY" "$TOOL_NAME" "$TOOL_INPUT" \
      || entries_look_tailored "[]" "$PDENY" "$TOOL_NAME" "$TOOL_INPUT"; then
      EVENT="asked_denied_always"
    fi
  fi
else
  # Success. Map sha state to event.
  if [ "$USER_CHANGED" -eq 0 ] && [ "$PROJ_CHANGED" -eq 0 ]; then
    EVENT="asked_allowed_once"
  else
    # Something in settings changed. Look for a plausibly-tailored entry.
    UALLOW="$(read_settings_allow "$USER_SETTINGS")"
    PALLOW="$(read_settings_allow "$PROJ_SETTINGS")"
    if entries_look_tailored "[]" "$UALLOW" "$TOOL_NAME" "$TOOL_INPUT" \
      || entries_look_tailored "[]" "$PALLOW" "$TOOL_NAME" "$TOOL_INPUT"; then
      EVENT="asked_allowed_always"
    else
      EVENT="asked_allowed_unknown"
    fi
  fi
fi

# --- 7. Write audit line ---------------------------------------------------
write_post_event "$EVENT" "$TOOL_NAME" "$TOOL_USE_ID"

emit_passthrough
exit 0
