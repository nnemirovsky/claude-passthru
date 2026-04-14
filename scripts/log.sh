#!/usr/bin/env bash
# claude-passthru audit log viewer.
#
# Reads ~/.claude/passthru-audit.log (JSONL, one event per line) and renders
# it in a human-friendly table, raw JSONL, or a JSON array. Also toggles the
# audit sentinel (~/.claude/passthru.audit.enabled) via --enable/--disable/
# --status.
#
# All paths honor PASSTHRU_USER_HOME so bats tests never touch real ~/.claude.
#
# Flags (see --help):
#   --file <path>             override audit log path
#   --since <val>             ISO 8601, relative (1h|24h|7d|30d|5m), or "today"
#   --event <regex>           filter on .event field
#   --tool <regex>            filter on .tool field
#   --format table|json|raw   default table
#   --tail N                  last N entries after filtering
#   --enable|--disable        toggle sentinel, exit 0
#   --status                  print enabled/disabled + log path, exit 0
#   --help                    short usage

set -euo pipefail

# Cache the OS once - we branch on Darwin vs Linux date semantics ~5 places
# below, and a fresh `uname -s` fork each call adds up across long log files.
PASSTHRU_OS="$(uname -s)"

# ---------------------------------------------------------------------------
# Path helpers (mirror hook handlers)
# ---------------------------------------------------------------------------

passthru_user_home() {
  printf '%s\n' "${PASSTHRU_USER_HOME:-$HOME}"
}

default_log_path() {
  printf '%s/.claude/passthru-audit.log\n' "$(passthru_user_home)"
}

sentinel_path() {
  printf '%s/.claude/passthru.audit.enabled\n' "$(passthru_user_home)"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: log.sh [options]

Filter and format the claude-passthru audit log.

Options:
  --file <path>             override log file path
  --since <value>           filter by time: ISO 8601 (2026-04-14T00:00:00Z),
                            relative (5m|1h|24h|7d|30d), or "today"
  --event <regex>           regex matched against the .event field
  --tool <regex>            regex matched against the .tool field
  --format table|json|raw   output format (default: table)
  --tail N                  show only the last N entries after filtering
  --enable                  touch the audit sentinel (enables logging)
  --disable                 remove the audit sentinel (disables logging)
  --status                  print enabled/disabled and log path, exit
  --help                    this help

The default log path is ~/.claude/passthru-audit.log and the sentinel is
~/.claude/passthru.audit.enabled. Both honor PASSTHRU_USER_HOME.
EOF
}

# ---------------------------------------------------------------------------
# OS detection for ISO 8601 parse
# ---------------------------------------------------------------------------

# parse_iso_to_epoch <iso8601>: prints epoch seconds, exits 2 on failure.
parse_iso_to_epoch() {
  local iso="$1"
  local epoch=""
  # Accept either bare "...Z" or "...Z" with no fractional secs.
  if [ "$PASSTHRU_OS" = "Darwin" ]; then
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)"
  else
    epoch="$(date -u -d "$iso" +%s 2>/dev/null || true)"
  fi
  if [ -z "$epoch" ] || ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  printf '%s\n' "$epoch"
}

# compute_cutoff <since-value>: prints epoch cutoff, exits 2 on bad input.
compute_cutoff() {
  local raw="$1"
  local now
  now="$(date -u +%s)"
  case "$raw" in
    today)
      # Local midnight today in epoch.
      if [ "$PASSTHRU_OS" = "Darwin" ]; then
        date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null \
          || return 2
      else
        date -d 'today 00:00:00' +%s 2>/dev/null || return 2
      fi
      return 0
      ;;
    *m)
      # Minutes
      local n="${raw%m}"
      [[ "$n" =~ ^[0-9]+$ ]] || return 2
      printf '%s\n' $((now - n * 60))
      return 0
      ;;
    *h)
      local n="${raw%h}"
      [[ "$n" =~ ^[0-9]+$ ]] || return 2
      printf '%s\n' $((now - n * 3600))
      return 0
      ;;
    *d)
      local n="${raw%d}"
      [[ "$n" =~ ^[0-9]+$ ]] || return 2
      printf '%s\n' $((now - n * 86400))
      return 0
      ;;
    *Z)
      parse_iso_to_epoch "$raw"
      return $?
      ;;
    *)
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

# tty_color: emit 0 if stdout is a tty and TERM != dumb, 1 otherwise.
tty_color() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    return 0
  fi
  return 1
}

# color_for_event <event>: emit ANSI color code, empty on no color.
color_for_event() {
  local event="$1"
  case "$event" in
    allow|asked_allowed_once|asked_allowed_always)
      printf '\033[32m'  # green
      ;;
    deny|asked_denied_once|asked_denied_always)
      printf '\033[31m'  # red
      ;;
    passthrough|asked_allowed_unknown)
      printf '\033[33m'  # yellow
      ;;
    *)
      printf ''
      ;;
  esac
}

# iso_to_local_display <iso8601> <today_date>
# Prints HH:MM:SS if the date matches $today_date (local YYYY-MM-DD),
# otherwise YYYY-MM-DD HH:MM.
iso_to_local_display() {
  local iso="$1" today="$2"
  local epoch local_date short_date
  if [ "$PASSTHRU_OS" = "Darwin" ]; then
    epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)"
  else
    epoch="$(date -u -d "$iso" +%s 2>/dev/null || true)"
  fi
  if [ -z "$epoch" ]; then
    printf '%s' "$iso"
    return 0
  fi
  if [ "$PASSTHRU_OS" = "Darwin" ]; then
    local_date="$(date -j -r "$epoch" +%Y-%m-%d 2>/dev/null || echo '')"
  else
    local_date="$(date -d "@$epoch" +%Y-%m-%d 2>/dev/null || echo '')"
  fi
  if [ "$local_date" = "$today" ]; then
    if [ "$PASSTHRU_OS" = "Darwin" ]; then
      date -j -r "$epoch" +'%H:%M:%S' 2>/dev/null || printf '%s' "$iso"
    else
      date -d "@$epoch" +'%H:%M:%S' 2>/dev/null || printf '%s' "$iso"
    fi
  else
    if [ "$PASSTHRU_OS" = "Darwin" ]; then
      short_date="$(date -j -r "$epoch" +'%Y-%m-%d %H:%M' 2>/dev/null || echo '')"
    else
      short_date="$(date -d "@$epoch" +'%Y-%m-%d %H:%M' 2>/dev/null || echo '')"
    fi
    if [ -n "$short_date" ]; then
      printf '%s' "$short_date"
    else
      printf '%s' "$iso"
    fi
  fi
}

# truncate_str <s> <max>
truncate_str() {
  local s="$1" max="$2"
  local len=${#s}
  if [ "$len" -le "$max" ]; then
    printf '%s' "$s"
  else
    printf '%s...' "${s:0:max-3}"
  fi
}

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

# filter_stream <cutoff_epoch_or_empty> <event_regex_or_empty> <tool_regex_or_empty>
# Reads JSONL on stdin, writes JSONL to stdout with only entries that pass.
# Malformed lines produce a stderr warning but do not abort.
filter_stream() {
  local cutoff="$1" event_re="$2" tool_re="$3"
  local line num=0
  while IFS= read -r line || [ -n "$line" ]; do
    num=$((num + 1))
    [ -z "$line" ] && continue
    # Parse with jq. Skip on parse failure, warn once.
    local parsed
    if ! parsed="$(jq -c '.' <<<"$line" 2>/dev/null)"; then
      printf '[passthru log] warning: skipping malformed line %d\n' "$num" >&2
      continue
    fi
    # Time cutoff
    if [ -n "$cutoff" ]; then
      local ts epoch
      ts="$(jq -r '.ts // ""' <<<"$parsed" 2>/dev/null || echo '')"
      if [ -z "$ts" ]; then
        continue
      fi
      if ! epoch="$(parse_iso_to_epoch "$ts")"; then
        continue
      fi
      if [ "$epoch" -lt "$cutoff" ]; then
        continue
      fi
    fi
    # Event regex
    if [ -n "$event_re" ]; then
      local ev rc
      ev="$(jq -r '.event // ""' <<<"$parsed" 2>/dev/null || echo '')"
      perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' "$ev" "$event_re" 2>/dev/null
      rc=$?
      # Perl's die on bad regex exits 255; treat as a hard error rather than
      # a silent "no match" so users see why their filter found nothing.
      if [ "$rc" -ge 2 ]; then
        printf '[passthru log] invalid --event regex: %s\n' "$event_re" >&2
        return 2
      fi
      if [ "$rc" -ne 0 ]; then
        continue
      fi
    fi
    # Tool regex
    if [ -n "$tool_re" ]; then
      local t rc
      t="$(jq -r '.tool // ""' <<<"$parsed" 2>/dev/null || echo '')"
      perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' "$t" "$tool_re" 2>/dev/null
      rc=$?
      if [ "$rc" -ge 2 ]; then
        printf '[passthru log] invalid --tool regex: %s\n' "$tool_re" >&2
        return 2
      fi
      if [ "$rc" -ne 0 ]; then
        continue
      fi
    fi
    printf '%s\n' "$parsed"
  done
}

# tail_stream <n>: emit only the last n lines.
# n is validated as a positive integer at flag-parse time. We still defend
# against direct callers passing 0 / empty by emitting nothing rather than
# the entire stream (which would be the surprising opposite of "tail").
tail_stream() {
  local n="$1"
  if [ -z "$n" ] || ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -eq 0 ]; then
    return 0
  fi
  tail -n "$n"
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------

render_table() {
  local today
  today="$(date +%Y-%m-%d)"
  local reset=""
  if tty_color; then
    reset='\033[0m'
  fi
  # Header
  printf '%-19s | %-22s | %-7s | %-18s | %s\n' 'time' 'event' 'source' 'tool' 'reason/detail'
  printf '%s\n' '-------------------------------------------------------------------------------------------'
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    local ts event source tool reason rule_index detail color
    ts="$(jq -r '.ts // ""' <<<"$line" 2>/dev/null || echo '')"
    event="$(jq -r '.event // ""' <<<"$line" 2>/dev/null || echo '')"
    source="$(jq -r '.source // ""' <<<"$line" 2>/dev/null || echo '')"
    tool="$(jq -r '.tool // ""' <<<"$line" 2>/dev/null || echo '')"
    reason="$(jq -r '.reason // ""' <<<"$line" 2>/dev/null || echo '')"
    rule_index="$(jq -r '.rule_index // empty' <<<"$line" 2>/dev/null || echo '')"

    if [ -n "$reason" ]; then
      detail="$reason"
    else
      # Fall back to tool_use_id short form for asked_* events.
      local tuid
      tuid="$(jq -r '.tool_use_id // ""' <<<"$line" 2>/dev/null || echo '')"
      if [ -n "$tuid" ]; then
        detail="$(truncate_str "$tuid" 24)"
      else
        detail=""
      fi
    fi
    if [ -n "$rule_index" ]; then
      detail="[#${rule_index}] ${detail}"
    fi
    detail="$(truncate_str "$detail" 60)"

    local time_str
    time_str="$(iso_to_local_display "$ts" "$today")"

    if tty_color; then
      color="$(color_for_event "$event")"
      printf "${color}%-19s | %-22s | %-7s | %-18s | %s${reset}\n" \
        "$time_str" "$event" "$source" "$(truncate_str "$tool" 18)" "$detail"
    else
      printf '%-19s | %-22s | %-7s | %-18s | %s\n' \
        "$time_str" "$event" "$source" "$(truncate_str "$tool" 18)" "$detail"
    fi
  done
}

render_json() {
  # Slurp validated JSONL into an array. Empty input -> empty array.
  # Filtering already canonicalizes each line via jq -c, so jq -s here cannot
  # fail in practice. No fallback path needed.
  jq -s '.'
}

render_raw() {
  cat
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ARG_FILE=""
ARG_SINCE=""
ARG_EVENT=""
ARG_TOOL=""
ARG_FORMAT="table"
ARG_TAIL=""
ACTION="view"

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { printf '[passthru log] --file requires a path\n' >&2; exit 2; }
      ARG_FILE="$2"
      shift 2
      ;;
    --since)
      [ $# -ge 2 ] || { printf '[passthru log] --since requires a value\n' >&2; exit 2; }
      ARG_SINCE="$2"
      shift 2
      ;;
    --event)
      [ $# -ge 2 ] || { printf '[passthru log] --event requires a regex\n' >&2; exit 2; }
      ARG_EVENT="$2"
      shift 2
      ;;
    --tool)
      [ $# -ge 2 ] || { printf '[passthru log] --tool requires a regex\n' >&2; exit 2; }
      ARG_TOOL="$2"
      shift 2
      ;;
    --format)
      [ $# -ge 2 ] || { printf '[passthru log] --format requires a value\n' >&2; exit 2; }
      case "$2" in
        table|json|raw) ARG_FORMAT="$2" ;;
        *)
          printf '[passthru log] invalid --format: %s\n' "$2" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --tail)
      [ $# -ge 2 ] || { printf '[passthru log] --tail requires N\n' >&2; exit 2; }
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        printf '[passthru log] --tail N must be a non-negative integer\n' >&2
        exit 2
      fi
      if [ "$2" -eq 0 ]; then
        printf '[passthru log] --tail must be > 0 (use omit-flag to see all entries)\n' >&2
        exit 2
      fi
      ARG_TAIL="$2"
      shift 2
      ;;
    --enable)
      ACTION="enable"
      shift
      ;;
    --disable)
      ACTION="disable"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      printf '[passthru log] unknown argument: %s\n' "$1" >&2
      printf '\n' >&2
      usage >&2
      exit 2
      ;;
  esac
done

LOG_PATH="${ARG_FILE:-$(default_log_path)}"
SENT_PATH="$(sentinel_path)"

# ---------------------------------------------------------------------------
# Sentinel-toggle actions
# ---------------------------------------------------------------------------

case "$ACTION" in
  enable)
    mkdir -p "$(dirname "$SENT_PATH")" 2>/dev/null || true
    touch "$SENT_PATH"
    printf 'audit enabled\n'
    printf 'log: %s\n' "$LOG_PATH"
    exit 0
    ;;
  disable)
    rm -f "$SENT_PATH"
    printf 'audit disabled\n'
    exit 0
    ;;
  status)
    if [ -e "$SENT_PATH" ]; then
      printf 'enabled\n'
    else
      printf 'disabled\n'
    fi
    printf 'log: %s\n' "$LOG_PATH"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# View action
# ---------------------------------------------------------------------------

if [ ! -f "$LOG_PATH" ]; then
  printf 'no entries\n' >&2
  exit 0
fi

if [ ! -s "$LOG_PATH" ]; then
  printf 'no entries\n' >&2
  exit 0
fi

CUTOFF=""
if [ -n "$ARG_SINCE" ]; then
  if ! CUTOFF="$(compute_cutoff "$ARG_SINCE")"; then
    printf '[passthru log] invalid --since value: %s\n' "$ARG_SINCE" >&2
    exit 2
  fi
fi

# Filter then tail then render. Everything is a pipeline so we never buffer the
# full file if we can help it.
# Capture exit code so a bad --event/--tool regex (filter_stream returns 2)
# surfaces as exit 2 to the caller.
FILTERED=""
filter_rc=0
FILTERED="$(filter_stream "$CUTOFF" "$ARG_EVENT" "$ARG_TOOL" <"$LOG_PATH")" || filter_rc=$?
if [ "$filter_rc" -ne 0 ]; then
  exit "$filter_rc"
fi

if [ -z "$FILTERED" ]; then
  printf 'no entries\n' >&2
  exit 0
fi

if [ -n "$ARG_TAIL" ]; then
  FILTERED="$(printf '%s\n' "$FILTERED" | tail_stream "$ARG_TAIL")"
fi

case "$ARG_FORMAT" in
  table)
    printf '%s\n' "$FILTERED" | render_table
    ;;
  json)
    printf '%s\n' "$FILTERED" | render_json
    ;;
  raw)
    printf '%s\n' "$FILTERED" | render_raw
    ;;
esac

exit 0
