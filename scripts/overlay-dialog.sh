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

# Build a human-readable preview from tool_input. Extract the most relevant
# field per tool type instead of showing raw JSON.
preview=""
if [ -n "$TOOL_INPUT_JSON" ]; then
  _extract() { jq -r --arg f "$1" '.[$f] // empty' <<<"$TOOL_INPUT_JSON" 2>/dev/null; }
  case "$TOOL_NAME" in
    Bash)
      preview="$(_extract command)" ;;
    WebFetch|WebSearch)
      preview="$(_extract url)"
      [ -z "$preview" ] && preview="$(_extract query)" ;;
    Read|Edit|Write|NotebookEdit|NotebookRead)
      preview="$(_extract file_path)" ;;
    Grep)
      preview="$(_extract pattern)"
      _path="$(_extract path)"
      [ -n "$_path" ] && preview="${preview}  (in ${_path})" ;;
    Glob)
      preview="$(_extract pattern)"
      _path="$(_extract path)"
      [ -n "$_path" ] && preview="${preview}  (in ${_path})" ;;
    Agent)
      preview="$(_extract description)"
      [ -z "$preview" ] && preview="$(_extract prompt | head -c 120)" ;;
    *)
      preview="$TOOL_INPUT_JSON" ;;
  esac
  # Fallback to raw JSON if extraction yielded nothing.
  [ -z "$preview" ] && preview="$TOOL_INPUT_JSON"
  max_preview=120
  truncated_len=$((max_preview - 3))
  if [ "${#preview}" -gt "$max_preview" ]; then
    preview="${preview:0:$truncated_len}..."
  fi
fi

render_main_menu() {
  # Move cursor to top-left and clear screen.
  printf '\033[H\033[2J'
  printf "${BOLD}Passthru Permission Prompt${RESET}\n\n"
  printf "Tool:  ${CYAN}%s${RESET}\n" "${TOOL_NAME:-(unknown)}"
  printf "Input: ${DIM}%s${RESET}\n\n" "$preview"

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

CONFIRM_LABELS=("[Enter] Accept rule" "[E] Edit rule JSON" "[Esc] Back to menu")
CONFIRM_KEYS=(enter e esc)
CONFIRM_COUNT=${#CONFIRM_LABELS[@]}
confirm_sel=0

render_confirm_menu() {
  printf '\033[H\033[2J'
  printf "${BOLD}Passthru Permission Prompt${RESET}\n\n"
  printf "Tool:  ${CYAN}%s${RESET}\n" "${TOOL_NAME:-(unknown)}"
  printf "Input: ${DIM}%s${RESET}\n\n" "$preview"
  printf "Suggested rule:\n"
  printf "  ${GREEN}%s${RESET}\n\n" "$proposed"

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

render_confirm_menu

while true; do
  read_key

  case "$KEY" in
    up)
      if [ "$confirm_sel" -gt 0 ]; then
        confirm_sel=$((confirm_sel - 1))
      else
        confirm_sel=$((CONFIRM_COUNT - 1))
      fi
      render_confirm_menu
      ;;
    down)
      if [ "$confirm_sel" -lt $((CONFIRM_COUNT - 1)) ]; then
        confirm_sel=$((confirm_sel + 1))
      else
        confirm_sel=0
      fi
      render_confirm_menu
      ;;
    enter)
      case "${CONFIRM_KEYS[$confirm_sel]}" in
        enter)
          write_verdict_always "$answer" "$proposed"
          exit 0
          ;;
        e)
          # Edit path below.
          break
          ;;
        esc)
          # Back to main menu. Re-run entire script via exec for simplicity.
          exec bash "$0"
          ;;
      esac
      ;;
    e)
      break  # fall through to edit
      ;;
    esc|timeout)
      # Back to main menu.
      exec bash "$0"
      ;;
    *)
      # Unknown key: ignore.
      ;;
  esac
done

# Edit path: read a full line with readline.
printf '\033[H\033[2J'
printf "${BOLD}Edit Rule JSON${RESET}\n\n"
printf "Current:\n  ${GREEN}%s${RESET}\n\n" "$proposed"
printf "Type new JSON (leave blank to accept):\n"
edited=""
if ! IFS= read -r -e -t "$TIMEOUT" edited; then
  exit 0
fi
if [ -z "$edited" ]; then
  write_verdict_always "$answer" "$proposed"
elif jq -e 'type == "object"' >/dev/null 2>&1 <<<"$edited"; then
  write_verdict_always "$answer" "$edited"
else
  printf '\n${RED}Invalid JSON (must be an object)${RESET}\n'
  printf 'Using suggested rule: %s\n' "$proposed"
  sleep 2
  write_verdict_always "$answer" "$proposed"
fi

exit 0
