#!/usr/bin/env bash
# claude-passthru common library, sourced by hook handlers and scripts.
# Provides rule file loading, merging, schema validation, and PCRE-based rule matching.
#
# Functions:
#   load_rules                 - read + merge up to four rule files, emit JSON on stdout.
#   validate_rules <json>      - schema-validate merged JSON, exit nonzero with message on violation.
#   pcre_match <subject> <pat> - PCRE match via perl. 0=match, 1=no-match, 2=bad-regex.
#   match_rule <tool_name> <tool_input_json> <rule_json> - 0=match, 1=no-match, 2=bad-regex.
#   find_first_match <rules_array_json> <tool_name> <tool_input_json> - first matching rule on stdout.
#
# All output is plain ASCII. Errors go to stderr. Functions return non-zero on failure
# without calling `exit` so callers can decide how to recover (hook handler fails open,
# verifier fails closed).
#
# Platform note: macOS ships BSD grep which lacks -P (PCRE). We use perl (default on macOS)
# for regex matching instead. Perl's regex engine is PCRE-compatible for the subset we use
# (anchors, character classes, alternation, quantifiers, non-capturing groups).

# Intentionally NOT setting `set -e` here. Callers decide error handling.
# This file is sourced, not executed.

# ---------------------------------------------------------------------------
# Canonical rule identity (jq filter source)
# ---------------------------------------------------------------------------
#
# PASSTHRU_CANON_JQ: a jq program fragment that, when fed a rule JSON document
# on input, emits that rule's canonical identity. Two rules collide iff their
# canonical forms are byte-identical. Identity is {tool, match} only: reason
# and any future cosmetic fields do not participate.
#
# Embed it into a jq call as either:
#   (a) a standalone filter:    jq "$PASSTHRU_CANON_JQ" <<<"$rule"
#   (b) a local function:       jq "def canon: $PASSTHRU_CANON_JQ | tojson; ..."
#
# Form (a) emits a JSON object. Form (b) composes with `| tojson` for a string
# form suitable for group_by / equality.
#
# Keeping the one definition here means verify.sh's dedup-canon logic and
# bootstrap.sh's import-time dedup logic cannot drift apart: a change to rule
# identity semantics is a single-line edit.
PASSTHRU_CANON_JQ='{tool:(.tool // null), match:(.match // null)}
         | walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end)'

# ---------------------------------------------------------------------------
# Shared environment helpers (used by hook handlers, scripts, and tests)
# ---------------------------------------------------------------------------

# passthru_user_home: resolve user home with env override support so tests
# can point at a synthetic ~/.claude.
passthru_user_home() {
  printf '%s\n' "${PASSTHRU_USER_HOME:-$HOME}"
}

# passthru_tmpdir: honor $TMPDIR, fall back to /tmp.
passthru_tmpdir() {
  printf '%s\n' "${TMPDIR:-/tmp}"
}

# passthru_iso_ts: UTC timestamp in ISO8601 with trailing Z.
passthru_iso_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# passthru_sha256 <path>: emit sha256 hex, or empty string if file missing.
# Detects shasum (macOS default) vs sha256sum (Linux).
passthru_sha256() {
  local path="$1"
  [ -f "$path" ] || return 0
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
  fi
}

# sanitize_tool_use_id <id>: emit a filesystem-safe form (only [A-Za-z0-9_-]).
# Anything else is stripped. Empty result -> empty stdout (caller skips work).
# This blocks path-traversal via crafted tool_use_id values that would
# otherwise land in $TMPDIR/passthru-pre-<id>.json.
sanitize_tool_use_id() {
  local id="$1"
  [ -z "$id" ] && return 0
  printf '%s' "$id" | tr -cd 'A-Za-z0-9_-'
}

# audit_enabled: 0 if sentinel ~/.claude/passthru.audit.enabled exists, 1 otherwise.
audit_enabled() {
  local sentinel
  sentinel="$(passthru_user_home)/.claude/passthru.audit.enabled"
  [ -e "$sentinel" ]
}

# ---------------------------------------------------------------------------
# Settings entry helpers (used by bootstrap + session-start hint)
# ---------------------------------------------------------------------------
#
# is_importable_entry <raw>
#   Returns 0 if bootstrap.sh's `convert_rule` would produce a rule for the
#   given native permission entry. Returns 1 otherwise. Single source of
#   truth so the session-start hash diff never drifts from what bootstrap
#   actually imports. Intentionally silent: no stdout, no stderr.
#
# Shapes accepted (must match convert_rule in scripts/bootstrap.sh):
#   Bash(<prefix>:*)                  -> importable when prefix non-empty
#   Bash(<exact command>)             -> importable when no embedded newline
#   WebFetch(domain:<domain>)         -> importable when domain non-empty
#   WebSearch                         -> importable (bare)
#   mcp__...                          -> importable when no parens
#   Read/Edit/Write(<path>[/**|/*])   -> importable when path passes
#                                       bootstrap's path-shape checks
#   Skill(<name>)                     -> importable when name non-empty
#
# Anything else returns 1.
is_importable_entry() {
  local raw="$1"

  # Trim whitespace (mirrors convert_rule).
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  [ -z "$raw" ] && return 1

  # Bash(...)
  if [[ "$raw" == Bash\(*\) ]]; then
    local inner="${raw#Bash(}"
    inner="${inner%)}"
    if [[ "$inner" == *:\* ]]; then
      local prefix="${inner%:\*}"
      [ -z "$prefix" ] && return 1
      return 0
    fi
    # Exact Bash command: reject embedded newline.
    [[ "$inner" == *$'\n'* ]] && return 1
    return 0
  fi

  # WebFetch(domain:...)
  if [[ "$raw" == WebFetch\(domain:*\) ]]; then
    local domain="${raw#WebFetch(domain:}"
    domain="${domain%)}"
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    [ -z "$domain" ] && return 1
    return 0
  fi

  # WebFetch(...) other than domain form: unsupported.
  if [[ "$raw" == WebFetch\(*\) ]]; then
    return 1
  fi

  # mcp__... (no parens)
  if [[ "$raw" == mcp__* ]]; then
    [[ "$raw" == *"("* ]] && return 1
    [[ "$raw" == *")"* ]] && return 1
    return 0
  fi

  # WebSearch (bare)
  if [ "$raw" = "WebSearch" ]; then
    return 0
  fi

  # Read/Edit/Write(<path>)
  if [[ "$raw" == Read\(*\) ]] || [[ "$raw" == Edit\(*\) ]] || [[ "$raw" == Write\(*\) ]]; then
    local tool_name="${raw%%(*}"
    local inner="${raw#${tool_name}(}"
    inner="${inner%)}"
    [ -z "$inner" ] && return 1
    # Shell / env expansion syntax: $, ${}, $(), %VAR%.
    [[ "$inner" == *'$'* ]] && return 1
    [[ "$inner" == *'%'* ]] && return 1
    # Leading = (zsh equals expansion).
    [[ "$inner" == =* ]] && return 1
    # UNC path.
    [[ "$inner" == '\\'* ]] && return 1
    # Tilde variants other than `~/` and bare `~`.
    if [ "$inner" = '~' ]; then
      return 0
    fi
    if [ "${inner:0:2}" = "~/" ]; then
      return 0
    fi
    if [ "${inner:0:1}" = "~" ]; then
      return 1
    fi
    return 0
  fi

  # Skill(<name>)
  if [[ "$raw" == Skill\(*\) ]]; then
    local name="${raw#Skill(}"
    name="${name%)}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [ -z "$name" ] && return 1
    return 0
  fi

  return 1
}

# normalize_settings_entry <entry>
#   Emits the entry with leading/trailing whitespace stripped. No lowercasing
#   (Claude Code's permission parser is case-sensitive - `Bash` != `bash`),
#   no path collapsing, no reformatting. The single contract: two entries
#   that differ only by surrounding whitespace hash identically.
normalize_settings_entry() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# hash_settings_entry <entry>
#   Emits sha256 hex of normalize_settings_entry(<entry>) on stdout.
#   Empty on error (missing hashing tools). Uses the same shasum/sha256sum
#   detection as passthru_sha256 but hashes stdin content instead of a path.
hash_settings_entry() {
  local normalized
  normalized="$(normalize_settings_entry "$1")"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$normalized" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$normalized" | sha256sum 2>/dev/null | awk '{print $1}'
  fi
}

# settings_importable_hashes
#   Scans every settings file (user + project shared/local) and emits one
#   hash per line for each `permissions.allow[]` string that passes
#   `is_importable_entry`. No output for missing files or empty allow
#   arrays. Malformed JSON files are silently skipped - the session-start
#   handler's job is nudging, not fault-reporting.
settings_importable_hashes() {
  local user_home project_dir
  user_home="$(passthru_user_home)"
  project_dir="${PASSTHRU_PROJECT_DIR:-$PWD}"

  local files=(
    "$user_home/.claude/settings.json"
    "$project_dir/.claude/settings.json"
    "$project_dir/.claude/settings.local.json"
  )

  local f entry
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    # Parse check is implicit: jq's error path returns no rows.
    # Only string entries count (matches bootstrap's filter).
    while IFS= read -r entry || [ -n "$entry" ]; do
      [ -z "$entry" ] && continue
      if is_importable_entry "$entry"; then
        hash_settings_entry "$entry"
      fi
    done < <(jq -r '(.permissions.allow // []) | map(select(type == "string")) | .[]' "$f" 2>/dev/null)
  done
}

# imported_hashes
#   Scans every passthru.imported.json file (user + project) and emits each
#   present `_source_hash` value on its own line. Rules without the field
#   contribute nothing (legacy pre-hash files silently force the hint to
#   re-fire until bootstrap rewrites them).
imported_hashes() {
  local user_imported project_imported
  user_imported="$(passthru_user_imported_path)"
  project_imported="$(passthru_project_imported_path)"

  local f
  for f in "$user_imported" "$project_imported"; do
    [ -f "$f" ] || continue
    jq -r '(.allow // []) | map(select(._source_hash != null and (._source_hash | type == "string"))) | .[]._source_hash' \
      "$f" 2>/dev/null
  done
}

# audit_log_path: path to ~/.claude/passthru-audit.log (may not exist).
audit_log_path() {
  printf '%s/.claude/passthru-audit.log\n' "$(passthru_user_home)"
}

# emit_passthrough: write the canonical passthrough JSON envelope to stdout.
# Used by every handler to fail-open on errors.
emit_passthrough() {
  printf '{"continue": true}\n'
}

# ---------------------------------------------------------------------------
# Overlay + permission-mode helpers
# ---------------------------------------------------------------------------
#
# These helpers are consumed by the PreToolUse hook in the Task 8 wiring so
# the same detection logic lives in one place (rather than drifting between
# the hook and `scripts/overlay.sh`). Keeping them in common.sh also makes
# them easy to unit test without spawning a whole hook invocation.

# overlay_disabled: returns 0 if the opt-out sentinel
# `~/.claude/passthru.overlay.disabled` exists, 1 otherwise. Honors
# PASSTHRU_USER_HOME so bats tests can plant / remove the sentinel freely.
overlay_disabled() {
  local sentinel
  sentinel="$(passthru_user_home)/.claude/passthru.overlay.disabled"
  [ -e "$sentinel" ]
}

# detect_overlay_multiplexer: internal detection shared with scripts/overlay.sh.
# Emits one of `tmux` / `kitty` / `wezterm` on stdout when a candidate env var
# is set AND its binary is on PATH. Returns 0 on success, 1 when nothing is
# usable (empty stdout).
#
# Order of preference matches scripts/overlay.sh exactly: tmux -> kitty ->
# wezterm. Both call sites (the hook via overlay_available and overlay.sh
# via its own detect_multiplexer) need to agree or the hook would claim the
# overlay is usable when overlay.sh would then refuse to launch.
detect_overlay_multiplexer() {
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    printf 'tmux'
    return 0
  fi
  if [ -n "${KITTY_WINDOW_ID:-}" ] && command -v kitty >/dev/null 2>&1; then
    printf 'kitty'
    return 0
  fi
  if [ -n "${WEZTERM_PANE:-}" ] && command -v wezterm >/dev/null 2>&1; then
    printf 'wezterm'
    return 0
  fi
  printf ''
  return 1
}

# overlay_available: returns 0 if at least one supported multiplexer is both
# announced (via env var) AND has its binary on PATH. Thin wrapper around
# detect_overlay_multiplexer for readable hook decision sites.
overlay_available() {
  local mux
  mux="$(detect_overlay_multiplexer 2>/dev/null || true)"
  [ -n "$mux" ]
}

# permission_mode_auto_allows <mode> <tool_name> <tool_input_json> <cwd>
#
# Returns 0 if Claude Code itself would auto-allow this tool call in the given
# permission mode, 1 otherwise.
#
# This is a *best-effort replication* of CC's internal
# src/utils/permissions/pathValidation.ts + per-tool auto-allow checkers. It
# is intentionally conservative: we err toward prompting the user (overlay
# path) rather than auto-allowing. Divergences (all in the SAFER direction):
#   - Symlink resolution: we use literal prefix match on "$cwd/". CC uses
#     realpathSync + pathInWorkingPath which follows symlinks. A symlink
#     `$cwd/link -> /elsewhere/foo` that CC would auto-allow via the real
#     path is NOT auto-allowed here (it falls through to overlay).
#   - `..` traversal: any path containing `/../` is rejected outright, even
#     when its literal prefix starts with $cwd/. CC's containsPathTraversal
#     covers this via path normalization.
#   - additionalAllowedWorkingDirs / sandbox allowlists / CC's internal
#     scratchpad paths: not considered. Calls to those dirs fall through.
#
# Mode behavior:
#   bypassPermissions: always 0 (everything auto-allowed).
#   acceptEdits:      0 for Write/Edit/NotebookEdit/MultiEdit when the
#                     target file_path resolves inside cwd. Non-edit tools
#                     in acceptEdits return 1.
#   default (+ empty mode value): 0 for read-only tools
#                     (Read/Grep/Glob/NotebookRead/LS) when the target path
#                     is inside cwd, plus WebFetch/WebSearch (CC auto-allows
#                     these without a path check). Everything else returns 1.
#   plan:             0 for Read/Grep/Glob/NotebookRead/LS (read-only,
#                     mutating tools are blocked by plan mode anyway). 1
#                     for any mutating tool.
#   Unknown mode:     1 (fail-safe: run the overlay).
permission_mode_auto_allows() {
  local mode="$1" tool_name="$2" tool_input="$3" cwd="$4"

  # A bypassPermissions session auto-allows every tool call - mirror that.
  if [ "$mode" = "bypassPermissions" ]; then
    return 0
  fi

  # Empty string / unset mode is treated as "default".
  [ -z "$mode" ] && mode="default"

  # Helper: return 0 when path is literally inside cwd and free of ../
  # traversal. We do NOT canonicalize paths, so a symlink inside cwd
  # pointing outside cwd still passes - documented as a known limitation.
  _pm_path_inside_cwd() {
    local p="$1" c="$2"
    [ -z "$p" ] && return 1
    [ -z "$c" ] && return 1
    # Reject `..` traversal anywhere in the path (including the middle).
    case "$p" in
      *'/../'*|*'/..') return 1 ;;
    esac
    # Literal prefix check: path must start with "$cwd/" (not just "$cwd").
    case "$p" in
      "$c"/*) return 0 ;;
    esac
    return 1
  }

  case "$mode" in
    acceptEdits)
      case "$tool_name" in
        Write|Edit|NotebookEdit|MultiEdit)
          local fp
          fp="$(jq -r '.file_path // ""' <<<"$tool_input" 2>/dev/null || printf '')"
          if _pm_path_inside_cwd "$fp" "$cwd"; then
            return 0
          fi
          return 1
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    default)
      case "$tool_name" in
        Read|NotebookRead)
          local fp
          fp="$(jq -r '.file_path // .notebook_path // ""' <<<"$tool_input" 2>/dev/null || printf '')"
          if _pm_path_inside_cwd "$fp" "$cwd"; then
            return 0
          fi
          return 1
          ;;
        Grep|Glob|LS)
          local gp
          gp="$(jq -r '.path // ""' <<<"$tool_input" 2>/dev/null || printf '')"
          # Grep/Glob/LS without a path default to cwd - auto-allow that.
          if [ -z "$gp" ]; then
            return 0
          fi
          if _pm_path_inside_cwd "$gp" "$cwd"; then
            return 0
          fi
          return 1
          ;;
        WebFetch|WebSearch)
          # CC auto-allows these in default mode (no path check).
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    plan)
      case "$tool_name" in
        Read|Grep|Glob|NotebookRead|LS)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      # Unknown mode (e.g. future CC addition). Fail-safe: run the overlay.
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Post-hook classification helpers
# ---------------------------------------------------------------------------
#
# Shared between post-tool-use.sh (success path + tool_response shapes) and
# post-tool-use-failure.sh (failure envelope). Both handlers read the
# PreToolUse breadcrumb, diff against the current settings.json shas, and
# classify the outcome into one of the `asked_*` events plus (for failures)
# the new `errored` event.

# write_post_event <event> <tool_name> <tool_use_id> [error_type]
# Appends one JSONL line to the audit log. Fail-open (never propagates errors).
# The optional 4th arg, when non-empty, is written as `error_type` to the log.
# That lets the new `errored` event carry the CC-provided error classification
# (for example `timeout`, `interrupted`, `not_found`) without breaking the
# existing 3-arg signature used by post-tool-use.sh.
write_post_event() {
  local event="$1" tool="$2" tool_use_id="$3" error_type="${4:-}"
  local path ts line dir
  path="$(audit_log_path)"
  ts="$(passthru_iso_ts)"

  line="$(
    jq -cn \
      --arg ts "$ts" \
      --arg event "$event" \
      --arg tool "$tool" \
      --arg tool_use_id "$tool_use_id" \
      --arg error_type "$error_type" \
      '{
        ts: $ts,
        event: $event,
        source: "native",
        tool: $tool,
        tool_use_id: (if $tool_use_id == "" then null else $tool_use_id end)
      }
      | (if $error_type == "" then . else (. + {error_type: $error_type}) end)' 2>/dev/null
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
#   - tool_response is the literal string "null" (explicit null payload)
#   - tool_response.permissionDenied is true
#   - tool_response.error / .errorMessage / .message matches an anchored
#     permission/access/blocked/denied/not-allowed token (underscore, hyphen,
#     or space separator variants all accepted)
#   - tool_response.status or .state equals one of:
#       "denied", "permission_denied", "permissionDenied", "blocked"
# Empty / missing tool_response is NOT classified as denied (no signal).
# Returns 0 when denied, 1 otherwise.
is_denied_response() {
  local resp="$1"
  # Empty payload: no signal at all. Treat as not-denied so we do not promote
  # ambiguous outcomes (e.g. background tools without a structured response)
  # into asked_denied_*.
  [ -z "$resp" ] && return 1
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
  if [ -n "$err" ]; then
    if printf '%s' "$err" | grep -qiE '(permission[- _]?denied|access[- _]?denied|not[- _]?allowed|\bblocked\b|\bdenied\b)'; then
      return 0
    fi
  fi
  status="$(jq -r '.status // .state // ""' <<<"$resp" 2>/dev/null || echo '')"
  case "$status" in
    denied|permission_denied|permissionDenied|blocked)
      return 0
      ;;
  esac
  return 1
}

# is_permission_error_string <error_string>
# Returns 0 if the error string from a failure-envelope (no JSON wrapper)
# matches any anchored permission-denied token. Reuses the same token set as
# is_denied_response so CC-generated denial strings classify identically in
# both the success-shaped path and the failure-envelope path.
is_permission_error_string() {
  local err="$1"
  [ -z "$err" ] && return 1
  if printf '%s' "$err" | grep -qiE '(permission[- _]?denied|access[- _]?denied|not[- _]?allowed|\bblocked\b|\bdenied\b)'; then
    return 0
  fi
  return 1
}

# entries_look_tailored <new_entries_json> <tool_name> <tool_input_json>
# Returns 0 if any entry in new_entries looks plausibly tied to the given
# tool call. Because the breadcrumb only persists a sha of the prior
# settings file (not the entries themselves), we test every entry in the
# current settings file rather than diffing. The worst case (false-positive
# `always` classification when the entry predated this call) still produces
# a truthful line: the rule does cover the call.
entries_look_tailored() {
  local new_entries="$1" tool_name="$2" tool_input="$3"

  [ -z "$new_entries" ] && return 1
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
      # Native `Bash(...)` permissions come in two flavors:
      #   Bash(ls:*)  -- prefix form; matches any command starting with `ls`
      #                  followed by whitespace or end-of-string.
      #   Bash(ls)    -- exact form; matches ONLY the literal command `ls`.
      [ -z "$entry_arg" ] && return 1
      local cmd
      cmd="$(jq -r '.command // ""' <<<"$tool_input" 2>/dev/null || echo '')"
      [ -z "$cmd" ] && return 1
      if [[ "$entry_arg" == *:\* ]]; then
        local prefix="${entry_arg%:\*}"
        [ -z "$prefix" ] && return 1
        case "$cmd" in
          "$prefix"|"$prefix "*) return 0 ;;
        esac
        return 1
      fi
      [ "$cmd" = "$entry_arg" ] && return 0
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
      host="${host%%\#*}"
      host="${host%%\?*}"
      host="${host%%/*}"
      host="${host%%:*}"
      [ -z "$host" ] && return 1
      if [ "$host" = "$want_host" ] || [[ "$host" == *".$want_host" ]]; then
        return 0
      fi
      return 1
      ;;
    Read|Edit|Write)
      [ -z "$entry_arg" ] && return 1
      local prefix="${entry_arg%:\*}"
      [ -z "$prefix" ] && return 1
      local fp
      fp="$(jq -r '.file_path // ""' <<<"$tool_input" 2>/dev/null || echo '')"
      [ -z "$fp" ] && return 1
      case "$fp" in
        "$prefix"|"$prefix"/*) return 0 ;;
      esac
      return 1
      ;;
    *)
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

# read_settings_deny <path>: emit permissions.deny as a JSON array, or "[]".
read_settings_deny() {
  local path="$1"
  [ -f "$path" ] || { printf '[]\n'; return 0; }
  jq -c '.permissions.deny // []' "$path" 2>/dev/null || printf '[]\n'
}

# classify_passthrough_outcome <denied_bool> <tool_name> <tool_input_json> \
#                              <old_user_sha> <old_proj_sha>
# Diffs the old breadcrumb shas against the current settings files and emits
# the classification event name on stdout. Does NOT write anything to the
# audit log; the caller invokes write_post_event with the returned event.
#
# Arguments:
#   denied_bool     - "1" if the outcome was denied (permission refusal),
#                     "0" if the outcome was a success shape.
#   tool_name       - the PostToolUse tool_name (used for entry tailoring).
#   tool_input_json - compact JSON (used for entry tailoring).
#   old_user_sha    - user settings.json sha recorded in the breadcrumb.
#   old_proj_sha    - project settings.local.json sha recorded in the breadcrumb.
#
# Output (stdout, one line, no newline):
#   asked_denied_once | asked_denied_always |
#   asked_allowed_once | asked_allowed_always | asked_allowed_unknown
classify_passthrough_outcome() {
  local denied="$1" tool_name="$2" tool_input="$3" old_user_sha="$4" old_proj_sha="$5"

  local user_settings proj_settings new_user_sha new_proj_sha
  local user_changed=0 proj_changed=0
  user_settings="$(passthru_user_home)/.claude/settings.json"
  proj_settings="${PASSTHRU_PROJECT_DIR:-$PWD}/.claude/settings.local.json"
  new_user_sha="$(passthru_sha256 "$user_settings")"
  new_proj_sha="$(passthru_sha256 "$proj_settings")"
  [ "$old_user_sha" != "$new_user_sha" ] && user_changed=1
  [ "$old_proj_sha" != "$new_proj_sha" ] && proj_changed=1

  local event=""
  if [ "$denied" = "1" ]; then
    event="asked_denied_once"
    if [ "$user_changed" -eq 1 ] || [ "$proj_changed" -eq 1 ]; then
      local udeny pdeny
      udeny="$(read_settings_deny "$user_settings")"
      pdeny="$(read_settings_deny "$proj_settings")"
      if entries_look_tailored "$udeny" "$tool_name" "$tool_input" \
        || entries_look_tailored "$pdeny" "$tool_name" "$tool_input"; then
        event="asked_denied_always"
      fi
    fi
  else
    if [ "$user_changed" -eq 0 ] && [ "$proj_changed" -eq 0 ]; then
      event="asked_allowed_once"
    else
      local uallow pallow
      uallow="$(read_settings_allow "$user_settings")"
      pallow="$(read_settings_allow "$proj_settings")"
      if entries_look_tailored "$uallow" "$tool_name" "$tool_input" \
        || entries_look_tailored "$pallow" "$tool_name" "$tool_input"; then
        event="asked_allowed_always"
      else
        event="asked_allowed_unknown"
      fi
    fi
  fi
  printf '%s' "$event"
}

# ---------------------------------------------------------------------------
# Rule file paths
# ---------------------------------------------------------------------------

# Resolve the four rule file paths. Uses $HOME for user scope and $PWD for project.
# Callers may override via environment:
#   PASSTHRU_USER_HOME   (default: $HOME)
#   PASSTHRU_PROJECT_DIR (default: $PWD)
# Separate env overrides make bats tests deterministic without touching real ~/.claude.
passthru_user_authored_path() {
  local base="${PASSTHRU_USER_HOME:-$HOME}"
  printf '%s/.claude/passthru.json\n' "$base"
}

passthru_user_imported_path() {
  local base="${PASSTHRU_USER_HOME:-$HOME}"
  printf '%s/.claude/passthru.imported.json\n' "$base"
}

passthru_project_authored_path() {
  local base="${PASSTHRU_PROJECT_DIR:-$PWD}"
  printf '%s/.claude/passthru.json\n' "$base"
}

passthru_project_imported_path() {
  local base="${PASSTHRU_PROJECT_DIR:-$PWD}"
  printf '%s/.claude/passthru.imported.json\n' "$base"
}

# ---------------------------------------------------------------------------
# load_rules
# ---------------------------------------------------------------------------
#
# Reads up to four rule files (any subset may exist):
#   ~/.claude/passthru.json           (user, hand-authored)
#   ~/.claude/passthru.imported.json  (user, bootstrap output)
#   $CWD/.claude/passthru.json            (project, hand-authored)
#   $CWD/.claude/passthru.imported.json   (project, bootstrap output)
#
# Missing files are skipped silently (treated as {}).
# Empty files are treated as {}.
# Malformed JSON fails with the offending path on stderr and non-zero return.
#
# Output: a single merged JSON object on stdout of the form
#   { "version": 2, "allow": [...], "deny": [...], "ask": [...] }
# where allow[], deny[], and ask[] are concatenated in this fixed order:
#   user-authored, user-imported, project-authored, project-imported.
# Ordering matters for shadowing reports and for first-match semantics.
#
# Schema v1 files contribute no ask[] entries (the ask[] key is v2-only).
# Schema v2 files may declare an ask[] array at the top level; v1 files
# that happen to contain ask[] have it ignored here (load_rules reads
# allow[] and deny[] only for v1). The merged document always emits
# version 2 because it is a strict superset of v1.
load_rules() {
  local files=()
  local p
  for p in \
    "$(passthru_user_authored_path)" \
    "$(passthru_user_imported_path)" \
    "$(passthru_project_authored_path)" \
    "$(passthru_project_imported_path)"; do
    if [ -f "$p" ]; then
      files+=("$p")
    fi
  done

  # Normalize each file: missing/empty -> {}, malformed -> error.
  # Each element becomes a JSON object with .allow[], .deny[], and .ask[]
  # (possibly empty). For v1 files, .ask[] is always dropped to empty so
  # downstream consumers never see ask rules from v1 sources.
  local tmpdir
  tmpdir="$(mktemp -d -t passthru-load.XXXXXX)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  local idx=0
  local f
  for f in "${files[@]}"; do
    # Empty file -> treat as {}.
    if [ ! -s "$f" ]; then
      printf '{}' > "${tmpdir}/${idx}.json"
      idx=$((idx + 1))
      continue
    fi
    # Parse check.
    if ! jq -e '.' "$f" >/dev/null 2>"${tmpdir}/err"; then
      printf '[ERR] failed to parse %s: %s\n' "$f" "$(cat "${tmpdir}/err")" >&2
      return 2
    fi
    # Normalize: ensure .allow, .deny, and .ask exist as arrays.
    # For v1 files, .ask is always reset to [] since ask[] is a v2-only key.
    if ! jq '
      . as $d
      | (.version // 1) as $v
      | {
          version: $v,
          allow: (.allow // []),
          deny: (.deny // []),
          ask: (if $v >= 2 then (.ask // []) else [] end)
        }
    ' "$f" > "${tmpdir}/${idx}.json" 2>"${tmpdir}/err"; then
      printf '[ERR] failed to normalize %s: %s\n' "$f" "$(cat "${tmpdir}/err")" >&2
      return 2
    fi
    idx=$((idx + 1))
  done

  # Merge: concat allow[], deny[], and ask[] across all inputs, preserve order.
  # If no files at all, emit empty skeleton.
  if [ "$idx" -eq 0 ]; then
    printf '{"version":2,"allow":[],"deny":[],"ask":[]}\n'
    return 0
  fi

  local inputs=()
  local i
  for ((i = 0; i < idx; i++)); do
    inputs+=("${tmpdir}/${i}.json")
  done

  jq -s '{
    version: 2,
    allow: ([.[].allow // []] | add),
    deny: ([.[].deny // []] | add),
    ask: ([.[].ask // []] | add)
  }' "${inputs[@]}"
}

# ---------------------------------------------------------------------------
# build_ordered_allow_ask
# ---------------------------------------------------------------------------
#
# Emit a JSON array of {list, merged_idx, rule} objects that walks allow[]
# and ask[] rules across the four rule files in DOCUMENT ORDER:
#   1. Scope order is fixed: user-authored -> user-imported ->
#      project-authored -> project-imported.
#   2. Within each file, the relative order between allow[] and ask[] is
#      taken from JSON key order (keys_unsorted). A file with
#      {"ask":[...], "allow":[...]} walks ask rules first; a file with
#      {"allow":[...], "ask":[...]} walks allow rules first.
#   3. Within each array, rules are walked in their JSON array order.
#
# The `merged_idx` field matches the rule's position in the merged allow[]
# or ask[] array that load_rules would produce. Keeps audit-log rule_index
# values consistent with `/passthru:list` output regardless of which path
# (allow-first vs ask-first) a given file takes.
#
# v1 files contribute no ask rules (matches load_rules' v1 handling).
# Missing files, empty files, and files with only a subset of keys are all
# handled gracefully; this function is silent (never prints diagnostics).
# On jq error (corrupt JSON already rejected by load_rules upstream) the
# function emits an empty array.
build_ordered_allow_ask() {
  local raw_files=()
  local p
  for p in \
    "$(passthru_user_authored_path)" \
    "$(passthru_user_imported_path)" \
    "$(passthru_project_authored_path)" \
    "$(passthru_project_imported_path)"; do
    if [ -f "$p" ] && [ -s "$p" ]; then
      raw_files+=("$p")
    fi
  done

  if [ "${#raw_files[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  # Feed the raw files as a single slurp so jq sees the ORIGINAL key order
  # (load_rules would normalize keys alphabetically and lose it). Invalid
  # JSON has already been flagged by load_rules; here we fall back to [].
  jq -s -c '
    . as $files
    | reduce range(0; $files | length) as $fi
        ({entries: [], allow_idx: 0, ask_idx: 0};
          . as $acc
          | ($files[$fi] // {}) as $doc
          | (($doc.version // 1)) as $ver
          | ($doc
             | keys_unsorted
             | map(select(. == "allow" or . == "ask"))
             # v1 files never contribute ask rules.
             | map(select(. == "allow" or $ver >= 2))) as $order
          | reduce $order[] as $key ($acc;
              . as $a2
              | ($doc[$key] // []) as $list
              | reduce range(0; $list | length) as $ri ($a2;
                  if $key == "allow"
                  then .entries += [{list: "allow", rule: $list[$ri], merged_idx: .allow_idx}]
                       | .allow_idx += 1
                  else .entries += [{list: "ask", rule: $list[$ri], merged_idx: .ask_idx}]
                       | .ask_idx += 1
                  end
                )
            )
        )
    | .entries
  ' "${raw_files[@]}" 2>/dev/null || printf '[]\n'
}

# ---------------------------------------------------------------------------
# validate_rules
# ---------------------------------------------------------------------------
#
# Usage: validate_rules <merged-json>
# Enforces:
#   - top-level .version is 1 or 2 (absent = ok, merged output always sets 2)
#   - .allow and .deny are arrays (possibly empty)
#   - on v2 only, .ask is an array (possibly empty)
#   - each rule object has at least one of "tool" or "match"
#   - if present, .tool is a non-empty string
#   - if present, .match is an object and every value is a non-empty string
# Does NOT compile-check PCRE at load time (per plan: deep regex checks live in verify.sh).
# Returns 0 if valid, nonzero with stderr message otherwise.
#
# Schema evolution: v1 files may still be in the wild. load_rules always emits
# v2 (since v2 is a strict superset), so validate_rules on loader output always
# sees version 2. When called on a raw v1 source file, validate_rules ignores
# any ask[] key (v1 does not recognize it). On v2, ask[] is validated using
# the same rule-shape validation as allow[] and deny[].
validate_rules() {
  local merged="$1"
  if [ -z "$merged" ]; then
    printf '[ERR] validate_rules: empty input\n' >&2
    return 2
  fi

  # Version check: accept 1 or 2; reject anything else.
  local ver
  ver="$(jq -r '.version // 1' <<<"$merged" 2>/dev/null)"
  if [ "$ver" != "1" ] && [ "$ver" != "2" ]; then
    printf '[ERR] unsupported rule schema version: %s (expected 1 or 2)\n' "$ver" >&2
    return 2
  fi

  # Ensure .allow and .deny are arrays (after normalization, they always are,
  # but validate_rules may be called on raw input too).
  local allow_type deny_type
  allow_type="$(jq -r '.allow | type' <<<"$merged" 2>/dev/null)"
  deny_type="$(jq -r '.deny | type' <<<"$merged" 2>/dev/null)"
  if [ "$allow_type" != "array" ] && [ "$allow_type" != "null" ]; then
    printf '[ERR] .allow must be an array, got %s\n' "$allow_type" >&2
    return 2
  fi
  if [ "$deny_type" != "array" ] && [ "$deny_type" != "null" ]; then
    printf '[ERR] .deny must be an array, got %s\n' "$deny_type" >&2
    return 2
  fi

  # On v2, also ensure .ask (if present) is an array.
  if [ "$ver" = "2" ]; then
    local ask_type
    ask_type="$(jq -r '.ask | type' <<<"$merged" 2>/dev/null)"
    if [ "$ask_type" != "array" ] && [ "$ask_type" != "null" ]; then
      printf '[ERR] .ask must be an array, got %s\n' "$ask_type" >&2
      return 2
    fi
  fi

  # Per-rule schema checks for allow[], deny[], and (on v2) ask[].
  # We pass the version as a jq arg so the same filter handles both schemas:
  # v2 walks ask[] too, v1 never does.
  local report
  report="$(jq -r --arg ver "$ver" '
    def check_rule(list_name):
      . as $entry
      | $entry.key as $i
      | $entry.value as $rule
      | (if (($rule | has("tool")) or ($rule | has("match"))) then empty
         else "\(list_name)[\($i)]: rule must have at least one of \"tool\" or \"match\""
         end),
        (if ($rule | has("tool")) then
           (if ($rule.tool | type) != "string" then
              "\(list_name)[\($i)]: .tool must be a string"
            elif ($rule.tool | length) == 0 then
              "\(list_name)[\($i)]: .tool must be non-empty"
            else empty end)
         else empty end),
        (if ($rule | has("match")) then
           (if ($rule.match | type) != "object" then
              "\(list_name)[\($i)]: .match must be an object"
            else
              ($rule.match | to_entries[] |
                 (if (.value | type) != "string" then
                    "\(list_name)[\($i)].match.\(.key): value must be a string"
                  elif (.value | length) == 0 then
                    "\(list_name)[\($i)].match.\(.key): value must be non-empty"
                  else empty end))
            end)
         else empty end);

    ( (.allow // []) | to_entries[] | check_rule("allow") ),
    ( (.deny  // []) | to_entries[] | check_rule("deny") ),
    ( if $ver == "2" then
        ( (.ask // []) | to_entries[] | check_rule("ask") )
      else empty end )
  ' <<<"$merged" 2>/dev/null)"

  # jq's `to_entries` numbering requires capturing index; the construction above
  # uses to_entries and passes .key into check_rule, which restores indexed output.
  # Any line in $report is a violation.
  if [ -n "$report" ]; then
    # Print each violation on stderr prefixed with [ERR] schema.
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      printf '[ERR] schema: %s\n' "$line" >&2
    done <<<"$report"
    return 2
  fi

  return 0
}

# ---------------------------------------------------------------------------
# pcre_match
# ---------------------------------------------------------------------------
#
# Usage: pcre_match <subject> <pattern>
# Returns:
#   0 if the subject matches the pattern
#   1 if the subject does not match
#   2 if the pattern fails to compile (invalid regex)
#
# Perl's regex engine is used here because macOS ships BSD grep which does not
# support -P. Perl is preinstalled on macOS and Linux distributions this plugin
# targets. Perl's regex flavor is PCRE-compatible for the patterns users write.
#
# The subject and pattern are passed as argv to perl to avoid shell-quoting
# hazards. Compile errors produce perl's die output on stderr (exit 255), which
# we translate to return 2. Match/no-match is exit 0/1 from perl's `exit(1)
# unless` idiom.
pcre_match() {
  local subject="$1"
  local pattern="$2"
  local rc=0
  perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' "$subject" "$pattern" 2>/dev/null
  rc=$?
  # Perl exits 0 on match, 1 on no-match, 255 on die from a bad regex. Anything
  # >=2 (including 255) collapses to our "bad pattern" sentinel.
  [ "$rc" -ge 2 ] && return 2
  return $rc
}

# ---------------------------------------------------------------------------
# match_rule
# ---------------------------------------------------------------------------
#
# Usage: match_rule <tool_name> <tool_input_json> <rule_json>
# Returns:
#   0 if the tool_name + tool_input satisfy the rule
#   1 if they do not
#   2 if a regex in the rule fails to compile (caller should identify which rule)
#
# Semantics (per plan):
#   * `tool` regex is matched against tool_name. Absent or empty tool = match any tool.
#   * For each key in `match`: extract tool_input[key] via jq -r; if the field is null
#     or missing, the rule fails. Else regex-match its value. All match keys must pass
#     (AND semantics).
#   * Absent or empty `match` = match any input.
match_rule() {
  local tool_name="$1"
  local tool_input="$2"
  local rule="$3"

  # 1. Check .tool regex (if present and non-empty) against tool_name.
  local tool_pat
  tool_pat="$(jq -r '.tool // ""' <<<"$rule" 2>/dev/null)"
  if [ -n "$tool_pat" ]; then
    pcre_match "$tool_name" "$tool_pat"
    local rc=$?
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    if [ "$rc" -ne 0 ]; then
      return 1
    fi
  fi

  # 2. Check .match object (if present and non-empty) against tool_input fields.
  # Stream (key, pattern) records from a single jq invocation. Bash's command
  # substitution strips NUL bytes, so we feed the NUL-separated stream from
  # jq directly into `read -d ''` via process substitution.
  local match_type
  match_type="$(jq -r '.match // empty | type' <<<"$rule" 2>/dev/null)"
  if [ "$match_type" != "object" ]; then
    # No .match (or .match not an object) - passes (match any input).
    return 0
  fi

  local match_keys_count
  match_keys_count="$(jq -r '.match | length' <<<"$rule" 2>/dev/null)"
  if [ -z "$match_keys_count" ] || [ "$match_keys_count" = "0" ]; then
    return 0
  fi

  # Stream key\x01pattern\x00 records. \x01 separates key from pattern within
  # a record (keys per JSON spec contain no \x01); \x00 ends each record.
  # `read -d ''` reads up to the next NUL, never seeing it as input data.
  local rec key pat field field_present rc
  while IFS= read -r -d '' rec; do
    key="${rec%%$'\x01'*}"
    pat="${rec#*$'\x01'}"
    if [ -z "$key" ]; then
      # Defensive: empty key from a malformed rule.
      return 1
    fi
    # Detect null/missing distinct from empty string. Use --arg to avoid
    # shell-injection via crafted key names.
    field_present="$(jq -r --arg k "$key" 'if has($k) and (.[$k] != null) then "1" else "0" end' <<<"$tool_input" 2>/dev/null)"
    if [ "$field_present" != "1" ]; then
      return 1
    fi
    field="$(jq -r --arg k "$key" '.[$k] // ""' <<<"$tool_input" 2>/dev/null)"
    pcre_match "$field" "$pat"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      return 2
    fi
    if [ "$rc" -ne 0 ]; then
      return 1
    fi
  done < <(jq -j '
    .match
    | to_entries
    | map("\(.key)\u0001\(.value)\u0000")
    | add // ""
  ' <<<"$rule" 2>/dev/null)

  return 0
}

# ---------------------------------------------------------------------------
# find_first_match
# ---------------------------------------------------------------------------
#
# Usage: find_first_match <rules_array_json> <tool_name> <tool_input_json>
# Output: TAB-separated record on stdout when a rule matches:
#           <rule-index>\t<compact rule JSON>
#         Empty stdout when no rule matches.
#         Callers split with: IDX="${out%%$'\t'*}"; RULE="${out#*$'\t'}"
# Return:
#   0 always on clean traversal (even if no match - check stdout for emptiness)
#   2 if a regex in any visited rule fails to compile; stderr carries the index + pattern
#
# The caller is responsible for selecting which list to pass in (e.g. .deny first,
# then .allow). No in-function jq path indirection, per plan.
#
# Returning the index alongside the rule lets callers skip a second jq pass
# (e.g. for audit-log rule_index) at no real complexity cost.
find_first_match() {
  local rules="$1"
  local tool_name="$2"
  local tool_input="$3"

  # Defensive: empty / null rules array means no match.
  if [ -z "$rules" ] || [ "$rules" = "null" ]; then
    return 0
  fi

  local n
  n="$(jq -r 'if type == "array" then length else 0 end' <<<"$rules" 2>/dev/null)"
  if [ -z "$n" ] || [ "$n" = "0" ]; then
    return 0
  fi

  local i rule rc
  for ((i = 0; i < n; i++)); do
    rule="$(jq -c ".[${i}]" <<<"$rules" 2>/dev/null)"
    match_rule "$tool_name" "$tool_input" "$rule"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\t%s\n' "$i" "$rule"
      return 0
    elif [ "$rc" -eq 2 ]; then
      printf '[ERR] regex compile failure at rule index %s: %s\n' "$i" "$rule" >&2
      return 2
    fi
    # rc == 1: no match, keep looking.
  done

  return 0
}
