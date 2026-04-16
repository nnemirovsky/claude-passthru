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
#              * ask:   same shape with "ask" (Claude Code surfaces the native
#                       permission dialog; plan Task 8 later replaces this with
#                       an overlay popup when available, falling back to this
#                       emit path when overlay is unavailable/disabled)
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

# audit_write_line <event> <tool_name> <reason_or_empty> <rule_index_or_empty> <pattern_or_empty> <tool_use_id_or_empty> [source]
# Appends one JSONL line. Fails silently on write error (fail-open).
#
# The optional 7th argument overrides the `source` field. Accepted values:
#   passthru       default, used by rule matches + plugin self-allow
#   overlay        decision came from the terminal-overlay dialog (Task 8)
#   passthru-mode  decision came from the replicated CC permission-mode
#                  auto-allow fast path (Task 8)
# Any other value is written verbatim (future-proofing). Empty -> `passthru`.
audit_write_line() {
  audit_enabled || return 0

  local event="$1" tool="$2" reason="$3" rule_index="$4" pattern="$5" tool_use_id="$6"
  local source="${7:-passthru}"
  [ -z "$source" ] && source="passthru"
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
      --arg source "$source" \
      --arg reason "$reason" \
      --arg rule_index "$rule_index" \
      --arg pattern "$pattern" \
      --arg tool_use_id "$tool_use_id" \
      '{
        ts: $ts,
        event: $event,
        source: $source,
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
  # $1 = "allow" | "deny" | "ask"
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

# emit_ask_fallback <reason_tag>
# Centralizes the six ask-emit fallback paths (overlay disabled / unavailable
# / script missing / launch failure / cancel / unknown verdict). Reads the
# enclosing scope for MATCHED, OVERLAY_REASON, OVERLAY_RULE_IDX, OVERLAY_PATTERN,
# TOOL_NAME, TOOL_INPUT, TOOL_USE_ID, and FALLBACK_ASK_REASON.
#
# Behavior (preserves per-path semantics):
#   * Emits permissionDecision:"ask" with the precomputed FALLBACK_ASK_REASON.
#   * If the precomputed MATCHED was an ask rule: logs the ask event with the
#     matched rule's reason / rule_index / pattern (so /passthru:log can still
#     attribute the prompt to the rule that triggered it).
#   * Otherwise: logs the ask event tagged with `reason_tag` (e.g. "overlay
#     cancel") and null rule_index / pattern (no rule matched).
#   * Drops a breadcrumb so PostToolUse can classify the native-dialog outcome.
#   * Exits 0 (all ask-fallback sites are terminal).
#
# Each call site shrinks to a single invocation, preventing the drift that
# previously left the unknown-verdict branch losing ask-rule metadata.
emit_ask_fallback() {
  local reason_tag="$1"
  emit_decision "ask" "$FALLBACK_ASK_REASON"
  if [ "$MATCHED" = "ask" ]; then
    audit_write_line "ask" "$TOOL_NAME" "$OVERLAY_REASON" "$OVERLAY_RULE_IDX" "$OVERLAY_PATTERN" "$TOOL_USE_ID"
  else
    audit_write_line "ask" "$TOOL_NAME" "$reason_tag" "" "" "$TOOL_USE_ID"
  fi
  audit_write_breadcrumb "$TOOL_USE_ID" "$TOOL_NAME" "$TOOL_INPUT"
  exit 0
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
# CC supplies permission_mode + cwd on the PreToolUse envelope. Missing fields
# are treated as "default" mode / current PWD so behavior stays safe when the
# plugin is invoked standalone (bats tests, pipe testing).
PERMISSION_MODE="$(jq -r '.permission_mode // ""' <<<"$INPUT" 2>/dev/null)"
CC_CWD="$(jq -r '.cwd // ""' <<<"$INPUT" 2>/dev/null)"
[ -z "$CC_CWD" ] && CC_CWD="${PASSTHRU_PROJECT_DIR:-$PWD}"

# GC old breadcrumbs early so every invocation keeps TMPDIR tidy. Does nothing
# when audit is disabled.
audit_gc_breadcrumbs

# --- 3. Plugin self-allow --------------------------------------------------
# Hardcoded allow for the plugin's own scripts so slash commands do not hit
# the native permission dialog. We only self-allow Bash calls; other tools
# would not invoke our scripts.
#
# Primary check: $CLAUDE_PLUGIN_ROOT (set by Claude Code on every hook
# invocation) is the authoritative install path, so it works across all
# install shapes. Real installs live at
#   ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
# not `.../claude-passthru/...` - the hardcoded repo-name regex we used
# previously never matched real installs and forced every slash command
# into the native permission dialog.
#
# Fallback: a broadened regex that accepts `passthru` as any path segment
# under .claude/plugins/, for the rare case where $CLAUDE_PLUGIN_ROOT is
# unset (manual pipe-testing, legacy harnesses).
if [ "$TOOL_NAME" = "Bash" ]; then
  SELF_CMD="$(jq -r '.command // ""' <<<"$TOOL_INPUT" 2>/dev/null)"
  if [ -n "$SELF_CMD" ]; then
    SELF_ALLOWED=0
    SELF_PATTERN=""

    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
      SELF_PREFIX="bash ${CLAUDE_PLUGIN_ROOT}/scripts/"
      case "$SELF_CMD" in
        "$SELF_PREFIX"*)
          stripped="${SELF_CMD#"$SELF_PREFIX"}"
          script="${stripped%% *}"
          case "$script" in
            verify.sh|write-rule.sh|bootstrap.sh|log.sh|overlay-config.sh|list.sh|remove-rule.sh)
              SELF_ALLOWED=1
              SELF_PATTERN="CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}"
              ;;
          esac
          ;;
      esac
    fi

    if [ "$SELF_ALLOWED" -eq 0 ]; then
      # Fallback regex for environments where $CLAUDE_PLUGIN_ROOT is not set.
      # Accepts either `passthru` or `claude-passthru` anywhere after
      # .claude/plugins/ and before /scripts/, covering the real install
      # shape (cache/<marketplace>/passthru/<ver>/scripts/) and the legacy
      # repo-name shape (.../claude-passthru/scripts/).
      SELF_RE='^bash /.*/\.claude/plugins/.*(claude-passthru|/passthru/).*/scripts/[a-z-]+\.sh( |$)'
      if pcre_match "$SELF_CMD" "$SELF_RE"; then
        SELF_ALLOWED=1
        SELF_PATTERN="$SELF_RE"
      fi
    fi

    if [ "$SELF_ALLOWED" -eq 1 ]; then
      emit_decision "allow" "passthru self-allow: plugin script"
      audit_write_line "allow" "$TOOL_NAME" "passthru self-allow" "" "$SELF_PATTERN" "$TOOL_USE_ID"
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
[ -z "$DENY_RULES" ] && DENY_RULES='[]'

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

# --- 6. Match allow + ask in document order --------------------------------
# build_ordered_allow_ask returns a JSON array of {list, merged_idx, rule}
# entries that walk each source file's allow[] and ask[] in the order they
# appear in that file (via keys_unsorted). First match wins, with the `list`
# field deciding whether we emit "allow" or "ask". merged_idx is the rule's
# position in the corresponding merged array (so audit rule_index stays
# consistent with /passthru:list output).
#
# Task 8 decision order:
#   1. deny[] first-match -> deny (handled above).
#   2. ask[] match (ignoring allow[]) -> overlay path.
#   3. allow[] match -> allow.
#   4. no match + mode auto-allows -> passthrough (CC handles it).
#   5. no match + mode does NOT auto-allow -> overlay path.
#
# We set OVERLAY_REASON when we decide overlay is the next step. Empty =>
# no overlay needed. Carries the audit reason / pattern / rule_index through
# to the overlay-result dispatch.
OVERLAY_REASON=""
OVERLAY_RULE_IDX=""
OVERLAY_PATTERN=""

ORDERED="$(build_ordered_allow_ask 2>/dev/null)"
[ -z "$ORDERED" ] && ORDERED='[]'

ORDERED_COUNT="$(jq -r 'if type == "array" then length else 0 end' <<<"$ORDERED" 2>/dev/null)"
[ -z "$ORDERED_COUNT" ] && ORDERED_COUNT=0

MATCHED=""   # "allow" | "ask" | ""
if [ "$ORDERED_COUNT" -gt 0 ]; then
  i=0
  while [ "$i" -lt "$ORDERED_COUNT" ]; do
    ENTRY="$(jq -c --argjson i "$i" '.[$i]' <<<"$ORDERED" 2>/dev/null)"
    LIST_TYPE="$(jq -r '.list // ""' <<<"$ENTRY" 2>/dev/null)"
    RULE="$(jq -c '.rule // {}' <<<"$ENTRY" 2>/dev/null)"
    RULE_IDX="$(jq -r '.merged_idx // 0' <<<"$ENTRY" 2>/dev/null)"

    # Catch match_rule's return code without letting `set -e` abort the loop
    # on the expected "no match" (rc=1) path.
    mrc=0
    match_rule "$TOOL_NAME" "$TOOL_INPUT" "$RULE" || mrc=$?
    if [ "$mrc" -eq 2 ]; then
      # Invalid regex in allow/ask rule. Fail open so a single bad rule
      # cannot block every tool call.
      printf '[passthru] %s rule regex error; passing through\n' "$LIST_TYPE" >&2
      emit_passthrough
      exit 0
    fi
    if [ "$mrc" -eq 0 ]; then
      MATCHED="$LIST_TYPE"
      REASON="$(jq -r '.reason // ""' <<<"$RULE" 2>/dev/null)"
      PATTERN="$(rule_pattern_summary "$RULE")"
      OVERLAY_REASON="$REASON"
      OVERLAY_RULE_IDX="$RULE_IDX"
      OVERLAY_PATTERN="$PATTERN"
      if [ "$LIST_TYPE" = "allow" ]; then
        if [ -n "$REASON" ]; then
          MSG="passthru allow: ${REASON}"
        else
          MSG="passthru allow: matched rule [${PATTERN}]"
        fi
        emit_decision "allow" "$MSG"
        audit_write_line "allow" "$TOOL_NAME" "$REASON" "$RULE_IDX" "$PATTERN" "$TOOL_USE_ID"
        exit 0
      fi
      # ask match: break out of the loop and head to the overlay path.
      break
    fi
    i=$((i + 1))
  done
fi

# --- 7. Internal tool pass-through -----------------------------------------
# Some tools are Claude Code internals (schema loading, task management, etc.)
# that should never trigger the overlay. Pass them through unconditionally.
if [ "$MATCHED" != "ask" ]; then
  case "$TOOL_NAME" in
    ToolSearch|Skill|TaskCreate|TaskUpdate|TaskGet|TaskList|TaskOutput|TaskStop|\
    AskUserQuestion|SendMessage|EnterPlanMode|ExitPlanMode|ScheduleWakeup|\
    CronCreate|CronDelete|CronList|Monitor|LSP|RemoteTrigger|\
    EnterWorktree|ExitWorktree|TeamCreate|TeamDelete)
      emit_passthrough
      exit 0
      ;;
  esac
fi

# --- 8. Overlay path -------------------------------------------------------
# Passthru handles ALL non-internal tool calls. There is no mode-based
# auto-allow shortcut. Every unmatched call goes to the overlay so the user
# always sees a prompt. CC's native dialog only fires as a fallback when the
# user explicitly cancels the overlay (Esc) or the overlay is unavailable.
#
# Reached when either:
#   * an ask[] rule matched, or
#   * no rule matched AND mode did NOT auto-allow.
# The overlay launches an interactive popup inside the user's multiplexer
# (tmux/kitty/wezterm). Result values drive the final decision:
#   yes_once    -> allow (this call only)
#   no_once     -> deny (this call only)
#   yes_always  -> write allow rule + allow this call
#   no_always   -> write deny rule + deny this call
#   cancel      -> permissionDecision:"ask" (native dialog fallback)
#   launch failure / overlay disabled / overlay unavailable
#               -> permissionDecision:"ask" (native dialog fallback)

# The reason carried forward to the user if we end up emitting a native-ask
# fallback ("permissionDecision":"ask"). For ask-rule matches we preserve
# the rule's reason; for no-match-fallback we synthesize a neutral reason.
FALLBACK_ASK_REASON=""
if [ "$MATCHED" = "ask" ]; then
  if [ -n "$OVERLAY_REASON" ]; then
    FALLBACK_ASK_REASON="passthru ask: ${OVERLAY_REASON}"
  else
    FALLBACK_ASK_REASON="passthru ask: matched rule [${OVERLAY_PATTERN}]"
  fi
else
  FALLBACK_ASK_REASON="passthru: no rule matched and mode ${PERMISSION_MODE:-default} does not auto-allow"
fi

# Overlay opt-out short-circuit: sentinel present -> skip overlay entirely,
# emit the native-dialog fallback. Drop a breadcrumb so post-tool-use.sh can
# classify the native-dialog outcome into asked_* audit events.
if overlay_disabled; then
  emit_ask_fallback "overlay disabled"
fi

# No multiplexer available: warn + emit native-dialog fallback. Log one
# stderr line per call (session-level dedup is fine to defer). Breadcrumb
# enables PostToolUse asked_* classification of the native-dialog outcome.
if ! overlay_available; then
  printf '[passthru] overlay enabled but no supported multiplexer (tmux/kitty/wezterm); falling back to native dialog\n' >&2
  emit_ask_fallback "overlay unavailable"
fi

# Overlay is available. Prep the per-call result file, invoke overlay.sh,
# read the verdict, and fan out to allow/deny/native-ask.
_overlay_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$_overlay_root" ]; then
  _PASSTHRU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _overlay_root="$(cd "${_PASSTHRU_SCRIPT_DIR}/../.." && pwd)"
fi
OVERLAY_SH="${_overlay_root}/scripts/overlay.sh"

if [ ! -f "$OVERLAY_SH" ]; then
  # Missing script is the same failure shape as a launch error: warn + fall
  # through to native dialog. Breadcrumb is required so PostToolUse can classify
  # the native-dialog outcome.
  printf '[passthru] overlay script not found at %s; falling back to native dialog\n' "$OVERLAY_SH" >&2
  emit_ask_fallback "overlay script missing"
fi

# Per-call result file. Use sanitized tool_use_id when available so
# concurrent calls do not clobber each other; fall back to mktemp otherwise.
_tmpdir="$(passthru_tmpdir)"
[ -d "$_tmpdir" ] || mkdir -p "$_tmpdir" 2>/dev/null || true
_safe_id="$(sanitize_tool_use_id "$TOOL_USE_ID")"
if [ -n "$_safe_id" ]; then
  OVERLAY_RESULT="${_tmpdir}/passthru-overlay-${_safe_id}.txt"
  # Remove any stale artifact from a previous call with the same id.
  rm -f "$OVERLAY_RESULT" 2>/dev/null || true
else
  OVERLAY_RESULT="$(mktemp "${_tmpdir}/passthru-overlay.XXXXXX" 2>/dev/null || printf '%s/passthru-overlay-%s.txt' "$_tmpdir" "$$")"
  # mktemp creates an empty file; we want the absent-file cancel signal
  # from overlay-dialog to work, so drop it here.
  rm -f "$OVERLAY_RESULT" 2>/dev/null || true
fi

# Export the env contract for overlay.sh + overlay-dialog.sh.
export PASSTHRU_OVERLAY_RESULT_FILE="$OVERLAY_RESULT"
export PASSTHRU_OVERLAY_TOOL_NAME="$TOOL_NAME"
export PASSTHRU_OVERLAY_TOOL_INPUT_JSON="$TOOL_INPUT"

# Invoke the overlay and capture its exit code. We have an ERR trap in place
# (converts unexpected errors to fail-open passthrough), so we cannot rely on
# `set +e` alone: the trap fires on any non-zero exit regardless. Disable the
# ERR trap around the overlay call, then re-arm it.
trap - ERR
set +e
bash "$OVERLAY_SH"
OVERLAY_RC=$?
set -e
trap 'printf "[passthru] unexpected error in pre-tool-use.sh\n" >&2; emit_passthrough; exit 0' ERR

if [ "$OVERLAY_RC" -ne 0 ]; then
  # Launch failure (rc 1 = no multiplexer detected at launch time, rc 2 =
  # popup error). Warn + fall through to native dialog so the user still
  # gets to approve/deny. Breadcrumb lets PostToolUse classify the outcome.
  printf '[passthru] overlay.sh exited %d; falling back to native dialog\n' "$OVERLAY_RC" >&2
  emit_ask_fallback "overlay launch failure"
fi

# Read the verdict. Absent / empty file -> cancel.
VERDICT=""
RULE_JSON_LINE=""
if [ -s "$OVERLAY_RESULT" ]; then
  VERDICT="$(head -n 1 "$OVERLAY_RESULT" 2>/dev/null || true)"
  RULE_JSON_LINE="$(sed -n '2p' "$OVERLAY_RESULT" 2>/dev/null || true)"
fi
# Best-effort cleanup of the result file; harmless if the file is already
# missing.
rm -f "$OVERLAY_RESULT" 2>/dev/null || true

case "$VERDICT" in
  yes_once)
    MSG="overlay: user approved once"
    emit_decision "allow" "$MSG"
    audit_write_line "allow" "$TOOL_NAME" "user approved once" "" "" "$TOOL_USE_ID" "overlay"
    exit 0
    ;;
  no_once)
    MSG="overlay: user denied once"
    emit_decision "deny" "$MSG"
    audit_write_line "deny" "$TOOL_NAME" "user denied once" "" "" "$TOOL_USE_ID" "overlay"
    exit 0
    ;;
  yes_always|no_always)
    # Persist the proposed rule via write-rule.sh. Scope is always user:
    # overlay-dialog.sh does not expose a scope picker today, and the
    # proposer never writes one. If a future overlay UX adds per-rule scope
    # selection, add scope extraction here then.
    target_list="allow"
    [ "$VERDICT" = "no_always" ] && target_list="deny"
    target_scope="user"
    if [ -n "$RULE_JSON_LINE" ] && jq -e '.' >/dev/null 2>&1 <<<"$RULE_JSON_LINE"; then
      _rule_to_write="$RULE_JSON_LINE"

      _write_rc=0
      _write_stderr=""
      WRITE_RULE_SH="${_overlay_root}/scripts/write-rule.sh"
      if [ -f "$WRITE_RULE_SH" ]; then
        # Same ERR-trap dance as the overlay invocation: disable before, re-arm
        # after, so a non-zero write-rule.sh does not tumble into the fail-open
        # passthrough path.
        #
        # Capture stderr so we can surface write-rule.sh diagnostics (verifier
        # errors, lock timeout, schema conflicts) to the user instead of
        # swallowing them. stdout stays discarded because write-rule.sh prints
        # its success banner there.
        trap - ERR
        set +e
        _write_stderr="$(bash "$WRITE_RULE_SH" "$target_scope" "$target_list" "$_rule_to_write" 2>&1 >/dev/null)"
        _write_rc=$?
        set -e
        trap 'printf "[passthru] unexpected error in pre-tool-use.sh\n" >&2; emit_passthrough; exit 0' ERR
      else
        _write_rc=1
      fi
      if [ "$_write_rc" -ne 0 ]; then
        printf '[passthru] overlay: write-rule.sh failed rc=%d for %s/%s; applying decision for this call only\n' \
          "$_write_rc" "$target_scope" "$target_list" >&2
        if [ -n "$_write_stderr" ]; then
          # Tag each line so users can grep the hook's output under --debug.
          while IFS= read -r _line; do
            printf '[passthru] write-rule: %s\n' "$_line" >&2
          done <<< "$_write_stderr"
        fi
      fi
    else
      printf '[passthru] overlay: %s verdict without valid rule JSON; applying decision for this call only\n' \
        "$VERDICT" >&2
    fi

    if [ "$VERDICT" = "yes_always" ]; then
      MSG="overlay: user approved always"
      emit_decision "allow" "$MSG"
      audit_write_line "allow" "$TOOL_NAME" "user approved always" "" "" "$TOOL_USE_ID" "overlay"
    else
      MSG="overlay: user denied always"
      emit_decision "deny" "$MSG"
      audit_write_line "deny" "$TOOL_NAME" "user denied always" "" "" "$TOOL_USE_ID" "overlay"
    fi
    exit 0
    ;;
  cancel|'')
    # Explicit cancel OR absent/empty result file both collapse to the
    # native-dialog fallback. Breadcrumb lets PostToolUse classify the
    # native-dialog outcome into asked_* events.
    emit_ask_fallback "overlay cancel"
    ;;
  *)
    # Unknown verdict string: treat as cancel (fail-safe). Breadcrumb keeps
    # PostToolUse classification coverage aligned with the other fallback
    # branches.
    printf '[passthru] overlay: unknown verdict %s; falling back to native dialog\n' "$VERDICT" >&2
    emit_ask_fallback "overlay unknown verdict"
    ;;
esac

# Unreachable, but keep the passthrough as a final fail-open safety net.
audit_write_line "passthrough" "$TOOL_NAME" "" "" "" "$TOOL_USE_ID"
audit_write_breadcrumb "$TOOL_USE_ID" "$TOOL_NAME" "$TOOL_INPUT"
emit_passthrough
exit 0
