#!/usr/bin/env bash
# claude-passthru overlay regex proposer.
#
# Given a tool_name + tool_input (JSON), emits a proposed rule JSON to stdout
# for the overlay's "yes always" / "no always" path. The proposer stays
# intentionally narrow: four explicit categories plus a minimal fallback.
# Anything more ambitious is a policy decision the user should make via
# /passthru:add.
#
# Usage:
#   overlay-propose-rule.sh <tool_name> <tool_input_json>
#
# Categories:
#   1. Bash(command=...)                 -> tool: "Bash", match.command:
#                                           "^<first-word>\\s"
#   2. Read/Edit/Write(file_path=...)    -> tool: "^(Read|Edit|Write)$",
#                                           match.file_path: "^<parent-dir>"
#   3. WebFetch/WebSearch(url=...)       -> tool: "^(WebFetch|WebSearch)$",
#                                           match.url: "^https?://<host>"
#   4. mcp__<server>__<method>           -> tool: "^mcp__<server>__",
#                                           no match block.
#
# Fallback (any other tool_name):
#   {"tool":"^<ExactName>$"}
#
# Output: one line of compact JSON, no trailing newline beyond jq's default.

set -euo pipefail

TOOL_NAME="${1:-}"
TOOL_INPUT="${2:-}"

if [ -z "$TOOL_NAME" ]; then
  printf '{"tool":"^Unknown$"}\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Regex-escape a literal for use inside a PCRE. We only need `.` (common in
# hosts + file paths) escaped. Other metachars are handled implicitly because
# we either anchor to `^` or rely on the categories themselves controlling
# what follows. Keep the escape list minimal to avoid over-escaping useful
# patterns like `-` in hostnames.
escape_regex() {
  local s="$1"
  # Escape dot and backslash only. The host/path content we emit is not
  # expected to contain regex meta beyond that in the common path.
  s="${s//\\/\\\\}"
  s="${s//./\\.}"
  printf '%s' "$s"
}

emit_fallback() {
  # Minimal, exact-name-anchored rule with no match block.
  jq -cn --arg name "$TOOL_NAME" '{tool: ("^" + $name + "$")}'
}

# Extract a field from the tool_input JSON. Returns empty string if absent
# or if JSON is malformed.
extract_field() {
  local field="$1"
  [ -z "$TOOL_INPUT" ] && { printf ''; return 0; }
  jq -r --arg f "$field" '(.[$f] // "") | tostring' <<<"$TOOL_INPUT" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# Category 1: Bash
# ---------------------------------------------------------------------------
if [ "$TOOL_NAME" = "Bash" ]; then
  cmd="$(extract_field "command")"
  if [ -z "$cmd" ]; then
    emit_fallback
    exit 0
  fi
  # First token = first word of the command. Trim leading whitespace then
  # split on whitespace.
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  first_word="${cmd%%[[:space:]]*}"
  if [ -z "$first_word" ]; then
    emit_fallback
    exit 0
  fi
  pattern="^$(escape_regex "$first_word")\\s"
  jq -cn --arg tool "Bash" --arg pat "$pattern" \
    '{tool: $tool, match: {command: $pat}}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Category 2: Read / Edit / Write
# ---------------------------------------------------------------------------
case "$TOOL_NAME" in
  Read|Edit|Write)
    fp="$(extract_field "file_path")"
    if [ -z "$fp" ]; then
      emit_fallback
      exit 0
    fi
    # Parent directory: strip everything after the last "/". If there is no
    # slash, fall back to exact-name-anchored rule (nothing meaningful to
    # prefix-match on).
    case "$fp" in
      */*)
        parent="${fp%/*}/"
        ;;
      *)
        emit_fallback
        exit 0
        ;;
    esac
    pattern="^$(escape_regex "$parent")"
    jq -cn --arg pat "$pattern" \
      '{tool: "^(Read|Edit|Write)$", match: {file_path: $pat}}'
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Category 3: WebFetch / WebSearch
# ---------------------------------------------------------------------------
case "$TOOL_NAME" in
  WebFetch|WebSearch)
    url="$(extract_field "url")"
    if [ -z "$url" ]; then
      emit_fallback
      exit 0
    fi
    # Host extraction mirrors common.sh's entry_matches_call approach:
    # strip scheme, fragment, query, path, and port.
    host="${url#*://}"
    host="${host%%\#*}"
    host="${host%%\?*}"
    host="${host%%/*}"
    host="${host%%:*}"
    if [ -z "$host" ]; then
      emit_fallback
      exit 0
    fi
    pattern="^https?://$(escape_regex "$host")"
    jq -cn --arg pat "$pattern" \
      '{tool: "^(WebFetch|WebSearch)$", match: {url: $pat}}'
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Category 4: MCP (mcp__<server>__<method>)
# ---------------------------------------------------------------------------
if [[ "$TOOL_NAME" == mcp__* ]]; then
  # Strip "mcp__" prefix, then take up to the next "__" to identify the server.
  rest="${TOOL_NAME#mcp__}"
  server="${rest%%__*}"
  if [ -z "$server" ] || [ "$server" = "$rest" ]; then
    # Shape like "mcp__" alone, or no double-underscore after the server. Fall
    # back to the safe default.
    emit_fallback
    exit 0
  fi
  pattern="^mcp__$(escape_regex "$server")__"
  jq -cn --arg pat "$pattern" '{tool: $pat}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback
# ---------------------------------------------------------------------------
emit_fallback
