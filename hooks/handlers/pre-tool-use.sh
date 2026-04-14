#!/usr/bin/env bash
# claude-passthru PreToolUse hook handler.
#
# Contract:
#   stdin  - JSON payload from Claude Code with at least:
#              { "tool_name": "...", "tool_input": {...}, "tool_use_id": "..." (optional) }
#   stdout - JSON decision:
#              * allow: { "hookSpecificOutput": { "hookEventName": "PreToolUse",
#                         "permissionDecision": "allow", "permissionDecisionReason": "..." } }
#              * deny:  same shape with "deny"
#              * passthrough: { "continue": true }
#   exit   - always 0. Hook failures fail open (passthrough) so plugin bugs never
#            block tool execution.
#
# Features:
#   - Emergency disable sentinel (~/.claude/passthru.disabled) short-circuits to
#     passthrough before loading any rules.
#   - Plugin self-allow: the plugin's own scripts (e.g. /passthru:add shelling out
#     to write-rule.sh) bypass user rules so slash commands work out-of-the-box.
#   - Deny priority over allow; both override the native permission dialog.
#   - Optional JSONL audit log (~/.claude/passthru-audit.log) when sentinel
#     ~/.claude/passthru.audit.enabled exists. Audit is OFF by default and
#     imposes zero cost when disabled.
#   - PreToolUse passthrough events drop a breadcrumb in $TMPDIR so a companion
#     PostToolUse handler can classify the native-dialog outcome later.
#
# Paths honor PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR / TMPDIR so bats tests
# never touch the real ~/.claude or /tmp.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate and source common.sh
# ---------------------------------------------------------------------------
# Prefer $CLAUDE_PLUGIN_ROOT when Claude Code sets it; fall back to a path
# relative to this script so `bash hooks/handlers/pre-tool-use.sh` works
# standalone (handy for bats tests and local pipe-testing).
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
# Small helpers
# ---------------------------------------------------------------------------
# passthru_user_home, passthru_tmpdir, passthru_iso_ts, passthru_sha256,
# sanitize_tool_use_id, audit_enabled, audit_log_path, emit_passthrough
# all live in common.sh and are shared with post-tool-use.sh and the
# scripts/.

# audit_write_line <event> <tool_name> <reason_or_empty> <rule_index_or_empty> <pattern_or_empty> <tool_use_id_or_empty>
# Appends one JSONL line. Fails silently on write error (fail-open).
audit_write_line() {
  audit_enabled || return 0

  local event="$1" tool="$2" reason="$3" rule_index="$4" pattern="$5" tool_use_id="$6"
  local path ts line
  path="$(audit_log_path)"
  ts="$(passthru_iso_ts)"

  # Build a compact JSON object via jq so strings are properly escaped.
  # Null sentinel: empty string in bash -> null in JSON (except when the empty
  # string is legitimate for reason/pattern - we treat empty as null for
  # simplicity; callers pass an explicit non-empty string when they have one).
  line="$(
    jq -cn \
      --arg ts "$ts" \
      --arg event "$event" \
      --arg tool "$tool" \
      --arg reason "$reason" \
      --arg rule_index "$rule_index" \
      --arg pattern "$pattern" \
      --arg tool_use_id "$tool_use_id" \
      '{
        ts: $ts,
        event: $event,
        source: "passthru",
        tool: $tool,
        reason: (if $reason == "" then null else $reason end),
        rule_index: (if $rule_index == "" then null else ($rule_index | tonumber) end),
        pattern: (if $pattern == "" then null else $pattern end),
        tool_use_id: (if $tool_use_id == "" then null else $tool_use_id end)
      }' 2>/dev/null
  )" || return 0
  [ -z "$line" ] && return 0

  # Ensure the parent directory exists; if not, skip (fail open).
  local dir
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0

  # Single printf append. Under POSIX, writes smaller than PIPE_BUF (>=512)
  # to an O_APPEND fd are atomic. A single JSONL line is well under that.
  printf '%s\n' "$line" >> "$path" 2>/dev/null || return 0
  return 0
}

# audit_write_breadcrumb <tool_use_id> <tool_name> <tool_input_json>
# Writes a JSON breadcrumb for PostToolUse to consume on passthrough.
# Skips silently if tool_use_id is empty or audit is disabled.
audit_write_breadcrumb() {
  audit_enabled || return 0

  local tool_use_id="$1" tool="$2" tool_input="$3"
  [ -z "$tool_use_id" ] && return 0
  # Sanitize before using as a path component.
  local safe_id
  safe_id="$(sanitize_tool_use_id "$tool_use_id")"
  [ -z "$safe_id" ] && return 0

  local tmpdir ts user_sha proj_sha user_settings proj_settings path crumb
  tmpdir="$(passthru_tmpdir)"
  ts="$(passthru_iso_ts)"
  user_settings="$(passthru_user_home)/.claude/settings.json"
  proj_settings="${PASSTHRU_PROJECT_DIR:-$PWD}/.claude/settings.local.json"
  user_sha="$(passthru_sha256 "$user_settings")"
  proj_sha="$(passthru_sha256 "$proj_settings")"

  path="${tmpdir}/passthru-pre-${safe_id}.json"

  # Use jq to build the crumb so tool_input is embedded as real JSON
  # (not a stringified payload). tool_input may be "null" if stdin was
  # malformed - jq tolerates that via fromjson try.
  crumb="$(
    jq -cn \
      --arg ts "$ts" \
      --arg tool "$tool" \
      --argjson tool_input "${tool_input:-null}" \
      --arg user_sha "$user_sha" \
      --arg proj_sha "$proj_sha" \
      '{
        ts: $ts,
        tool: $tool,
        tool_input: $tool_input,
        settings_sha_user: (if $user_sha == "" then null else $user_sha end),
        settings_sha_project: (if $proj_sha == "" then null else $proj_sha end)
      }' 2>/dev/null
  )" || return 0
  [ -z "$crumb" ] && return 0

  printf '%s\n' "$crumb" > "$path" 2>/dev/null || return 0
  return 0
}

# audit_gc_breadcrumbs: unlink passthru-pre-*.json files older than 60 minutes.
# Cheap, best-effort. Errors are swallowed.
audit_gc_breadcrumbs() {
  audit_enabled || return 0
  local tmpdir
  tmpdir="$(passthru_tmpdir)"
  find "$tmpdir" -maxdepth 1 -name 'passthru-pre-*.json' -mmin +60 -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
# emit_passthrough lives in common.sh.

emit_decision() {
  # $1 = "allow" | "deny"
  # $2 = reason string
  local decision="$1" reason="$2"
  jq -cn \
    --arg decision "$decision" \
    --arg reason "$reason" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: $decision,
        permissionDecisionReason: $reason
      }
    }'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Fail-open wrapper: any unexpected error exits with passthrough.
trap 'printf "[passthru] unexpected error in pre-tool-use.sh\n" >&2; emit_passthrough; exit 0' ERR

# --- 1. Emergency disable sentinel -----------------------------------------
# Check BEFORE reading stdin so even a totally broken rule set cannot block
# tool use as long as the sentinel is present.
DISABLED_SENTINEL="$(passthru_user_home)/.claude/passthru.disabled"
if [ -e "$DISABLED_SENTINEL" ]; then
  emit_passthrough
  exit 0
fi

# --- 2. Read stdin ---------------------------------------------------------
INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(cat || true)"
fi

# Malformed or empty stdin -> passthrough + stderr warning.
if [ -z "$INPUT" ]; then
  printf '[passthru] warning: empty stdin; passing through\n' >&2
  emit_passthrough
  exit 0
fi

if ! jq -e '.' >/dev/null 2>&1 <<<"$INPUT"; then
  printf '[passthru] warning: malformed stdin JSON; passing through\n' >&2
  emit_passthrough
  exit 0
fi

# INPUT was already validated as JSON by `jq -e '.'` above, so these calls
# cannot fail. Defensively allow `// ""` defaults for missing fields.
TOOL_NAME="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null)"
TOOL_INPUT="$(jq -c '.tool_input // {}' <<<"$INPUT" 2>/dev/null)"
TOOL_USE_ID="$(jq -r '.tool_use_id // ""' <<<"$INPUT" 2>/dev/null)"

# GC old breadcrumbs early so every invocation keeps TMPDIR tidy. Does nothing
# when audit is disabled.
audit_gc_breadcrumbs

# --- 3. Plugin self-allow --------------------------------------------------
# Hardcoded allow for the plugin's own scripts so slash commands do not hit
# the native permission dialog. Matches e.g.:
#   bash /Users/foo/.claude/plugins/cache/umputun/claude-passthru/1.0.0/plugins/claude-passthru/scripts/verify.sh
# We only self-allow Bash calls; other tools would not invoke our scripts.
if [ "$TOOL_NAME" = "Bash" ]; then
  SELF_CMD="$(jq -r '.command // ""' <<<"$TOOL_INPUT" 2>/dev/null)"
  if [ -n "$SELF_CMD" ]; then
    # Plugin install path on disk is ~/.claude/plugins/... so the leading dot
    # in .claude must be escaped for regex (literal dot).
    SELF_RE='^bash /.*/\.claude/plugins/.*/claude-passthru/scripts/[a-z-]+\.sh( |$)'
    if pcre_match "$SELF_CMD" "$SELF_RE"; then
      emit_decision "allow" "passthru self-allow: plugin script"
      audit_write_line "allow" "$TOOL_NAME" "passthru self-allow" "" "$SELF_RE" "$TOOL_USE_ID"
      exit 0
    fi
  fi
fi

# --- 4. Load + validate rules ----------------------------------------------
# load_rules or validate_rules failure -> fail open with stderr diagnostic.
# Capture stdout directly; load_rules sends parse errors to stderr (which we
# let surface to Claude Code's --debug stream) and we pass the merged JSON
# back via stdout. No temp-file ping-pong, no $TMPDIR guesswork.
MERGED=""
if ! MERGED="$(load_rules 2>/dev/null)"; then
  printf '[passthru] load_rules failed; passing through\n' >&2
  emit_passthrough
  exit 0
fi

if [ -z "$MERGED" ]; then
  printf '[passthru] load_rules produced no output; passing through\n' >&2
  emit_passthrough
  exit 0
fi

if ! validate_rules "$MERGED" 2>/dev/null; then
  printf '[passthru] validate_rules failed; passing through\n' >&2
  emit_passthrough
  exit 0
fi

# --- 5. Match deny first ---------------------------------------------------
DENY_RULES="$(jq -c '.deny // []' <<<"$MERGED" 2>/dev/null)"
ALLOW_RULES="$(jq -c '.allow // []' <<<"$MERGED" 2>/dev/null)"
[ -z "$DENY_RULES" ] && DENY_RULES='[]'
[ -z "$ALLOW_RULES" ] && ALLOW_RULES='[]'

DENY_HIT=""
if DENY_HIT="$(find_first_match "$DENY_RULES" "$TOOL_NAME" "$TOOL_INPUT" 2>/dev/null)"; then
  :  # normal path
else
  # rc=2 (bad regex). Fail open.
  printf '[passthru] deny rule regex error; passing through\n' >&2
  emit_passthrough
  exit 0
fi

# rule_pattern_summary: emit a human-readable summary of the rule's pattern
# field for log output. Format:
#   - .tool only            -> "<tool-regex>"
#   - .tool + .match        -> "<tool-regex> | key1=<pat>, key2=<pat>"
#   - .match only           -> "key1=<pat>, key2=<pat>"
#   - neither               -> ""
# Captures all match keys (not just the first) so multi-key rules are
# faithfully represented in the audit log.
rule_pattern_summary() {
  local rule="$1"
  jq -r '
    [ (if .tool then .tool else empty end) ]
    + [ (.match // {} | to_entries | map("\(.key)=\(.value)") | join(", ")) ]
    | map(select(. != ""))
    | join(" | ")
  ' <<<"$rule" 2>/dev/null
}

if [ -n "$DENY_HIT" ]; then
  # find_first_match returns "<index>\t<rule-json>" so we split here.
  DENY_IDX="${DENY_HIT%%$'\t'*}"
  DENY_MATCH="${DENY_HIT#*$'\t'}"
  REASON="$(jq -r '.reason // ""' <<<"$DENY_MATCH" 2>/dev/null)"
  PATTERN="$(rule_pattern_summary "$DENY_MATCH")"
  if [ -n "$REASON" ]; then
    MSG="passthru deny: ${REASON} [${PATTERN}]"
  else
    MSG="passthru deny: matched rule [${PATTERN}]"
  fi
  emit_decision "deny" "$MSG"
  audit_write_line "deny" "$TOOL_NAME" "$REASON" "$DENY_IDX" "$PATTERN" "$TOOL_USE_ID"
  exit 0
fi

# --- 6. Match allow --------------------------------------------------------
ALLOW_HIT=""
if ALLOW_HIT="$(find_first_match "$ALLOW_RULES" "$TOOL_NAME" "$TOOL_INPUT" 2>/dev/null)"; then
  :
else
  printf '[passthru] allow rule regex error; passing through\n' >&2
  emit_passthrough
  exit 0
fi

if [ -n "$ALLOW_HIT" ]; then
  ALLOW_IDX="${ALLOW_HIT%%$'\t'*}"
  ALLOW_MATCH="${ALLOW_HIT#*$'\t'}"
  REASON="$(jq -r '.reason // ""' <<<"$ALLOW_MATCH" 2>/dev/null)"
  PATTERN="$(rule_pattern_summary "$ALLOW_MATCH")"
  if [ -n "$REASON" ]; then
    MSG="passthru allow: ${REASON}"
  else
    MSG="passthru allow: matched rule [${PATTERN}]"
  fi
  emit_decision "allow" "$MSG"
  audit_write_line "allow" "$TOOL_NAME" "$REASON" "$ALLOW_IDX" "$PATTERN" "$TOOL_USE_ID"
  exit 0
fi

# --- 7. Passthrough --------------------------------------------------------
audit_write_line "passthrough" "$TOOL_NAME" "" "" "" "$TOOL_USE_ID"
audit_write_breadcrumb "$TOOL_USE_ID" "$TOOL_NAME" "$TOOL_INPUT"
emit_passthrough
exit 0
