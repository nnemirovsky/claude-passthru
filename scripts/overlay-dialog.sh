#!/usr/bin/env bash
# claude-passthru overlay dialog (TUI body).
#
# Runs INSIDE the popup spawned by scripts/overlay.sh. Reads tool_name and
# tool_input (as compact JSON) from env vars, renders a Y/A/N/D/Esc menu
# with arrow-key navigation, optionally walks the user through a "accept or
# edit" regex proposal on the always-variants, and writes its verdict to
# $PASSTHRU_OVERLAY_RESULT_FILE.
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
OVERLAY_CWD="${PASSTHRU_OVERLAY_CWD:-${PWD}}"
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

# ANSI helpers.
BOLD='\033[1m'
DIM='\033[34m'
REVERSE='\033[7m'
GREEN='\033[32m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

# read_key: read a single keypress (handling multi-byte arrow sequences).
# Sets KEY to one of: up, down, enter, esc, y, a, n, d, e, or "other".
read_key() {
  KEY=""
  local byte=""
  if ! IFS= read -r -s -n 1 -t "$TIMEOUT" byte; then
    KEY="timeout"
    return
  fi
  case "$byte" in
    $'\e')
      # Escape: could be plain Esc or start of arrow/function sequence.
      local seq1=""
      if IFS= read -r -s -n 1 -t 0.1 seq1; then
        if [ "$seq1" = "[" ]; then
          local seq2=""
          if IFS= read -r -s -n 1 -t 0.1 seq2; then
            case "$seq2" in
              A) KEY="up"; return ;;
              B) KEY="down"; return ;;
              *) KEY="other"; return ;;
            esac
          fi
        fi
        KEY="other"
      else
        KEY="esc"
      fi
      ;;
    ""|$'\n')
      KEY="enter"
      ;;
    *)
      KEY="$(printf '%s' "$byte" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Test short-circuit path
# ---------------------------------------------------------------------------
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
      :
      ;;
    *)
      :
      ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Interactive path: main menu
# ---------------------------------------------------------------------------

MENU_LABELS=("[Y] Yes, once" "[A] Yes, always (with custom rule)" "[N] No, once" "[D] No, always (deny rule)" "[Esc] Skip (use native dialog)")
MENU_KEYS=(y a n d esc)
MENU_COUNT=${#MENU_LABELS[@]}
selected=0

# Build a human-readable preview from tool_input. Each tool type gets a
# tailored display. MCP tools show pretty JSON. Edits show a diff preview.
_extract() { jq -r --arg f "$1" '.[$f] // empty' <<<"$TOOL_INPUT_JSON" 2>/dev/null; }
_truncate() {
  local s="$1" max="${2:-120}"
  if [ "${#s}" -gt "$max" ]; then
    printf '%s...' "${s:0:$((max - 3))}"
  else
    printf '%s' "$s"
  fi
}

# preview_lines: array of lines to display. Populated per tool type.
preview_lines=()
extra_height=0  # additional lines beyond standard 1-line preview

if [ -n "$TOOL_INPUT_JSON" ]; then
  case "$TOOL_NAME" in
    Bash)
      preview_lines+=("$(_truncate "$(_extract command)" 120)")
      ;;
    WebFetch)
      preview_lines+=("$(_extract url)")
      ;;
    WebSearch)
      _q="$(_extract query)"
      [ -n "$_q" ] && preview_lines+=("search: $_q") || preview_lines+=("$(_extract url)")
      ;;
    Edit|Write)
      preview_lines+=("$(_extract file_path)")
      ;;
    Read|NotebookRead)
      preview_lines+=("$(_extract file_path)")
      ;;
    NotebookEdit)
      _fp="$(_extract file_path)"
      _cell="$(_extract cell_id)"
      preview_lines+=("$_fp")
      [ -n "$_cell" ] && preview_lines+=("cell: $_cell") && extra_height=1
      ;;
    Grep)
      _pat="$(_extract pattern)"
      _path="$(_extract path)"
      preview_lines+=("/$_pat/")
      [ -n "$_path" ] && preview_lines+=("in: $_path") && extra_height=1
      ;;
    Glob)
      _pat="$(_extract pattern)"
      _path="$(_extract path)"
      preview_lines+=("$_pat")
      [ -n "$_path" ] && preview_lines+=("in: $_path") && extra_height=1
      ;;
    Skill)
      _skill="$(_extract skill)"
      _args="$(_extract args)"
      if [ -n "$_args" ]; then
        preview_lines+=("$_skill $_args")
      else
        preview_lines+=("$_skill")
      fi
      ;;
    Agent)
      _desc="$(_extract description)"
      [ -n "$_desc" ] && preview_lines+=("$_desc") || preview_lines+=("$(_truncate "$(_extract prompt)" 120)")
      ;;
    mcp__*)
      # MCP tools: pretty-print the JSON args with indentation.
      _pretty="$(jq -r '.' <<<"$TOOL_INPUT_JSON" 2>/dev/null || echo "$TOOL_INPUT_JSON")"
      _line_count=0
      _total_lines=0
      while IFS= read -r _line; do
        _total_lines=$((_total_lines + 1))
        if [ "$_line_count" -lt 10 ]; then
          preview_lines+=("$_line")
          _line_count=$((_line_count + 1))
        fi
      done <<<"$_pretty"
      if [ "$_total_lines" -gt 10 ]; then
        _remaining=$((_total_lines - 10))
        preview_lines+=("  ... (${_remaining} more lines)")
        _line_count=$((_line_count + 1))
      fi
      extra_height=$((_line_count - 1))
      ;;
    *)
      preview_lines+=("$(_truncate "$TOOL_INPUT_JSON" 120)")
      ;;
  esac
fi
# Fallback if nothing was extracted.
if [ "${#preview_lines[@]}" -eq 0 ]; then
  preview_lines+=("$(_truncate "$TOOL_INPUT_JSON" 120)")
fi

# Session context for the header (helps distinguish multiple CC sessions).
_display_cwd="$OVERLAY_CWD"
case "$_display_cwd" in
  "$HOME"/*) _display_cwd="~${_display_cwd#"$HOME"}" ;;
  "$HOME")   _display_cwd="~" ;;
esac
# Session label: prefer CC session name (CLAUDE_SESSION_NAME) if set,
# fall back to tmux window name, then omit.
_session_label=""
if [ -n "${CLAUDE_SESSION_NAME:-}" ]; then
  _session_label="$CLAUDE_SESSION_NAME"
elif [ -n "${TMUX:-}" ]; then
  _w="$(tmux display-message -p '#W' 2>/dev/null || true)"
  [ -n "$_w" ] && _session_label="$_w"
fi

_render_header() {
  printf "${BOLD}Passthru Permission Prompt${RESET}\n"
  printf "\033[2mcwd: %s\033[0m\n" "$_display_cwd"
  if [ -n "$_session_label" ]; then
    printf "\033[2msession: %s\033[0m\n" "$_session_label"
  fi
  printf '\n'
}

render_main_menu() {
  printf '\033[H\033[2J'
  _render_header
  printf "Tool:  ${CYAN}%s${RESET}\n" "${TOOL_NAME:-(unknown)}"
  # Render preview lines.
  local first=1
  for _pline in "${preview_lines[@]}"; do
    if [ "$first" -eq 1 ]; then
      printf "Input: ${DIM}%b${RESET}\n" "$_pline"
      first=0
    else
      printf "       ${DIM}%b${RESET}\n" "$_pline"
    fi
  done
  printf '\n'

  local i
  for ((i = 0; i < MENU_COUNT; i++)); do
    if [ "$i" -eq "$selected" ]; then
      printf "  ${REVERSE} %s ${RESET}\n" "${MENU_LABELS[$i]}"
    else
      printf "   %s\n" "${MENU_LABELS[$i]}"
    fi
  done
  printf "\n\033[2mUse arrow keys or press a letter key\033[0m\n"
}

render_main_menu

while true; do
  read_key

  case "$KEY" in
    up)
      if [ "$selected" -gt 0 ]; then
        selected=$((selected - 1))
      else
        selected=$((MENU_COUNT - 1))
      fi
      render_main_menu
      ;;
    down)
      if [ "$selected" -lt $((MENU_COUNT - 1)) ]; then
        selected=$((selected + 1))
      else
        selected=0
      fi
      render_main_menu
      ;;
    enter)
      # Confirm the current selection.
      case "${MENU_KEYS[$selected]}" in
        y)  write_verdict_once "yes_once"; exit 0 ;;
        a)  break ;;  # fall through to always-confirm flow
        n)  write_verdict_once "no_once"; exit 0 ;;
        d)  break ;;  # fall through to always-confirm flow
        esc) exit 0 ;;
      esac
      ;;
    y)
      write_verdict_once "yes_once"
      exit 0
      ;;
    a)
      selected=1  # yes_always
      break
      ;;
    n)
      write_verdict_once "no_once"
      exit 0
      ;;
    d)
      selected=3  # no_always
      break
      ;;
    esc|timeout)
      exit 0
      ;;
    *)
      # Unknown key: ignore, keep looping.
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Always-variant: confirm/edit proposed rule
# ---------------------------------------------------------------------------

if [ "${MENU_KEYS[$selected]}" = "a" ]; then
  answer="yes_always"
else
  answer="no_always"
fi

proposed="$(propose_rule)"

# Extract tool regex and match fields from the proposed rule for two-field editing.
prop_tool="$(jq -r '.tool // ""' <<<"$proposed" 2>/dev/null)"
prop_match_key="$(jq -r '.match // empty | keys[0] // empty' <<<"$proposed" 2>/dev/null)"
prop_match_val="$(jq -r '.match // empty | to_entries[0].value // empty' <<<"$proposed" 2>/dev/null)"

render_rule_editor() {
  printf '\033[H\033[2J'
  _render_header "$_display_cwd"
  printf "Tool:  ${CYAN}%s${RESET}\n" "${TOOL_NAME:-(unknown)}"
  local _first=1
  for _pl in "${preview_lines[@]}"; do
    if [ "$_first" -eq 1 ]; then
      printf "Input: ${DIM}%b${RESET}\n" "$_pl"
      _first=0
    else
      printf "       ${DIM}%b${RESET}\n" "$_pl"
    fi
  done
  printf '\n'
  printf "Suggested rule:\n"
  printf "  Tool regex:  ${GREEN}%s${RESET}\n" "$prop_tool"
  if [ -n "$prop_match_key" ]; then
    printf "  Match %-6s ${GREEN}%s${RESET}\n" "${prop_match_key}:" "$prop_match_val"
  fi
  printf '\n'
}

CONFIRM_LABELS=("[Enter] Accept rule" "[E] Edit fields" "[Esc] Back to menu")
CONFIRM_KEYS=(enter e esc)
CONFIRM_COUNT=${#CONFIRM_LABELS[@]}
confirm_sel=0

render_confirm_screen() {
  render_rule_editor
  local i
  for ((i = 0; i < CONFIRM_COUNT; i++)); do
    if [ "$i" -eq "$confirm_sel" ]; then
      printf "  ${REVERSE} %s ${RESET}\n" "${CONFIRM_LABELS[$i]}"
    else
      printf "   %s\n" "${CONFIRM_LABELS[$i]}"
    fi
  done
  printf "\n\033[2mUse arrow keys or press a letter key\033[0m\n"
}

render_confirm_screen

while true; do
  read_key

  case "$KEY" in
    up)
      confirm_sel=$(( (confirm_sel - 1 + CONFIRM_COUNT) % CONFIRM_COUNT ))
      render_confirm_screen
      ;;
    down)
      confirm_sel=$(( (confirm_sel + 1) % CONFIRM_COUNT ))
      render_confirm_screen
      ;;
    enter)
      case "${CONFIRM_KEYS[$confirm_sel]}" in
        enter) break ;;
        e)
          # Two-field editor below.
          printf '\033[H\033[2J'
          printf "${BOLD}Edit Rule${RESET}\n\n"
          printf "Edit each field (pre-filled, use arrow keys to navigate).\n\n"
          printf "Tool regex: "
          edited_tool=""
          IFS= read -r -e -i "$prop_tool" -t "$TIMEOUT" edited_tool || true
          [ -z "$edited_tool" ] && edited_tool="$prop_tool"
          if [ -n "$prop_match_key" ]; then
            printf "Match %s: " "$prop_match_key"
            edited_match=""
            IFS= read -r -e -i "$prop_match_val" -t "$TIMEOUT" edited_match || true
            [ -z "$edited_match" ] && edited_match="$prop_match_val"
            prop_match_val="$edited_match"
          fi
          prop_tool="$edited_tool"
          # Rebuild and re-render.
          render_confirm_screen
          ;;
        esc)
          exec bash "$0"
          ;;
      esac
      ;;
    e)
      # Two-field editor (shortcut).
      printf '\033[H\033[2J'
      printf "${BOLD}Edit Rule${RESET}\n\n"
      printf "Edit each field. Leave blank to keep the suggested value.\n\n"
      printf "Tool regex ${DIM}[%s]${RESET}: " "$prop_tool"
      edited_tool=""
      IFS= read -r -e -t "$TIMEOUT" edited_tool || true
      [ -z "$edited_tool" ] && edited_tool="$prop_tool"
      if [ -n "$prop_match_key" ]; then
        printf "Match %s ${DIM}[%s]${RESET}: " "$prop_match_key" "$prop_match_val"
        edited_match=""
        IFS= read -r -e -t "$TIMEOUT" edited_match || true
        [ -z "$edited_match" ] && edited_match="$prop_match_val"
        prop_match_val="$edited_match"
      fi
      prop_tool="$edited_tool"
      render_confirm_screen
      ;;
    esc|timeout)
      exec bash "$0"
      ;;
    *)
      ;;
  esac
done

# Build the final rule JSON from the (possibly edited) fields.
if [ -n "$prop_match_key" ] && [ -n "$prop_match_val" ]; then
  final_rule="$(jq -cn --arg t "$prop_tool" --arg k "$prop_match_key" --arg v "$prop_match_val" \
    '{tool: $t, match: {($k): $v}}')"
else
  final_rule="$(jq -cn --arg t "$prop_tool" '{tool: $t}')"
fi
write_verdict_always "$answer" "$final_rule"

exit 0
