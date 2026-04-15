#!/usr/bin/env bash
# claude-passthru rule list viewer.
#
# Renders every known rule (user-authored, user-imported, project-authored,
# project-imported) with annotations suitable for UI consumption: scope,
# source, list (allow/deny), and 1-based index within the source file's
# list array. The index is the same number /passthru:remove accepts, so
# users can pipe this output into the remove command without guessing.
#
# Flags (see --help):
#   --scope user|project|all    default all
#   --list allow|deny|all       default all
#   --source authored|imported|all   default all
#   --tool <regex>              perl regex on .tool field
#   --format table|json|raw     default table
#   --flat                      skip grouped rendering; one flat table
#   --help                      usage
#
# All paths honor PASSTHRU_USER_HOME + PASSTHRU_PROJECT_DIR.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate and source common.sh
# ---------------------------------------------------------------------------
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh"
else
  _PASSTHRU_LIST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_COMMON="${_PASSTHRU_LIST_DIR}/../hooks/common.sh"
  if [ ! -f "$_PASSTHRU_COMMON" ]; then
    printf 'list.sh: cannot locate hooks/common.sh (tried CLAUDE_PLUGIN_ROOT and %s)\n' \
      "$_PASSTHRU_COMMON" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$_PASSTHRU_COMMON"
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: list.sh [options]

List passthru rules across user and project scopes with annotations.

Options:
  --scope user|project|all    default all
  --list allow|deny|all       default all
  --source authored|imported|all   default all
  --tool <regex>              perl regex on .tool field
  --format table|json|raw     default table
  --flat                      emit a single flat table (no grouping)
  --help                      this help

Table output is grouped by (scope, list, source) unless --flat is given.
Each rule gets a 1-based index matching its position within its source
file's list array. That index is what /passthru:remove accepts.

The default log paths are ~/.claude/passthru.json (authored) and
~/.claude/passthru.imported.json (imported) for the user scope, and the
corresponding files under $PWD/.claude for the project scope. All paths
honor PASSTHRU_USER_HOME and PASSTHRU_PROJECT_DIR.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

ARG_SCOPE="all"
ARG_LIST="all"
ARG_SOURCE="all"
ARG_TOOL=""
ARG_FORMAT="table"
ARG_FLAT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      [ $# -ge 2 ] || { printf '[passthru list] --scope requires a value\n' >&2; exit 2; }
      case "$2" in
        user|project|all) ARG_SCOPE="$2" ;;
        *) printf '[passthru list] invalid --scope: %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --list)
      [ $# -ge 2 ] || { printf '[passthru list] --list requires a value\n' >&2; exit 2; }
      case "$2" in
        allow|deny|all) ARG_LIST="$2" ;;
        *) printf '[passthru list] invalid --list: %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --source)
      [ $# -ge 2 ] || { printf '[passthru list] --source requires a value\n' >&2; exit 2; }
      case "$2" in
        authored|imported|all) ARG_SOURCE="$2" ;;
        *) printf '[passthru list] invalid --source: %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --tool)
      [ $# -ge 2 ] || { printf '[passthru list] --tool requires a regex\n' >&2; exit 2; }
      ARG_TOOL="$2"
      shift 2
      ;;
    --format)
      [ $# -ge 2 ] || { printf '[passthru list] --format requires a value\n' >&2; exit 2; }
      case "$2" in
        table|json|raw) ARG_FORMAT="$2" ;;
        *) printf '[passthru list] invalid --format: %s\n' "$2" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --flat)
      ARG_FLAT=1
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
      printf '[passthru list] unknown argument: %s\n' "$1" >&2
      printf '\n' >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Load rule files and annotate each rule
# ---------------------------------------------------------------------------
# Build a JSON array of annotated rule objects:
#   { scope, source, list, index, path, rule }
# where `index` is 1-based.

ANNOTATED="[]"

read_file_or_empty() {
  local p="$1"
  if [ -f "$p" ] && [ -s "$p" ]; then
    if jq -e '.' "$p" >/dev/null 2>&1; then
      cat "$p"
    else
      printf '{"version":1,"allow":[],"deny":[]}'
    fi
  else
    printf '{"version":1,"allow":[],"deny":[]}'
  fi
}

# annotate_list <scope> <source> <list> <path>
annotate_list() {
  local scope="$1" source="$2" list="$3" path="$4"
  local content annotated_chunk
  content="$(read_file_or_empty "$path")"
  annotated_chunk="$(jq -c \
    --arg scope "$scope" \
    --arg source "$source" \
    --arg list "$list" \
    --arg path "$path" '
      (.[$list] // [])
      | to_entries
      | map({
          scope: $scope,
          source: $source,
          list: $list,
          index: (.key + 1),
          path: $path,
          rule: .value
        })
    ' <<<"$content")"
  # Merge into ANNOTATED.
  ANNOTATED="$(jq -c -n \
    --argjson acc "$ANNOTATED" \
    --argjson chunk "$annotated_chunk" '
      $acc + $chunk
    ')"
}

# Scope order: user first, project second. Within each scope:
# authored first, then imported. Each file contributes allow then deny.
for scope in user project; do
  case "$ARG_SCOPE" in
    all) ;;
    "$scope") ;;
    *) continue ;;
  esac
  for source in authored imported; do
    case "$ARG_SOURCE" in
      all) ;;
      "$source") ;;
      *) continue ;;
    esac
    case "${scope}.${source}" in
      user.authored)    path="$(passthru_user_authored_path)" ;;
      user.imported)    path="$(passthru_user_imported_path)" ;;
      project.authored) path="$(passthru_project_authored_path)" ;;
      project.imported) path="$(passthru_project_imported_path)" ;;
    esac
    for list in allow deny; do
      case "$ARG_LIST" in
        all) ;;
        "$list") ;;
        *) continue ;;
      esac
      annotate_list "$scope" "$source" "$list" "$path"
    done
  done
done

# ---------------------------------------------------------------------------
# Apply --tool filter (regex on .tool field; missing tool -> empty string).
# ---------------------------------------------------------------------------

if [ -n "$ARG_TOOL" ]; then
  # Pre-compile check so a bad regex surfaces as exit 2.
  if ! perl -e 'eval { qr/$ARGV[0]/ } or exit 2' "$ARG_TOOL" 2>/dev/null; then
    printf '[passthru list] invalid --tool regex: %s\n' "$ARG_TOOL" >&2
    exit 2
  fi
  FILTERED="[]"
  N_TOTAL="$(jq -r 'length' <<<"$ANNOTATED")"
  for ((i = 0; i < N_TOTAL; i++)); do
    entry="$(jq -c ".[${i}]" <<<"$ANNOTATED")"
    tool_val="$(jq -r '.rule.tool // ""' <<<"$entry")"
    if perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' "$tool_val" "$ARG_TOOL" 2>/dev/null; then
      FILTERED="$(jq -c -n \
        --argjson acc "$FILTERED" \
        --argjson item "$entry" '
          $acc + [$item]
        ')"
    fi
  done
  ANNOTATED="$FILTERED"
fi

# ---------------------------------------------------------------------------
# Empty-set short circuit
# ---------------------------------------------------------------------------

N_FINAL="$(jq -r 'length' <<<"$ANNOTATED")"
if [ "$N_FINAL" -eq 0 ]; then
  printf 'no rules found\n' >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Color helpers (match log.sh semantics: tty + TERM != dumb).
# ---------------------------------------------------------------------------

tty_color() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    return 0
  fi
  return 1
}

color_for_list() {
  case "$1" in
    allow) printf '\033[32m' ;;
    deny)  printf '\033[31m' ;;
    *)     printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

truncate_str() {
  local s="$1" max="$2"
  local len=${#s}
  if [ "$len" -le "$max" ]; then
    printf '%s' "$s"
  else
    printf '%s...' "${s:0:max-3}"
  fi
}

# match_summary <rule-json>: "key1: pat1, key2: pat2" or "-".
match_summary() {
  local rule="$1"
  local summary
  summary="$(jq -r '
    if (.match // null) == null or (.match | length == 0) then
      "-"
    else
      .match | to_entries | map("\(.key): \(.value)") | join(", ")
    end
  ' <<<"$rule")"
  printf '%s' "$summary"
}

rule_reason() {
  local rule="$1"
  jq -r '.reason // ""' <<<"$rule"
}

rule_tool() {
  local rule="$1"
  jq -r '.tool // ""' <<<"$rule"
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------

render_flat_table() {
  local use_color=0
  tty_color && use_color=1
  local reset=""
  [ "$use_color" -eq 1 ] && reset='\033[0m'
  printf '%-8s %-6s %-9s %4s  %-18s %-40s %s\n' \
    'scope' 'list' 'source' '#' 'tool' 'match-summary' 'reason'
  printf '%s\n' '------------------------------------------------------------------------------------------------------'
  local n i entry scope list source idx tool match_sum reason color
  n="$(jq -r 'length' <<<"$ANNOTATED")"
  for ((i = 0; i < n; i++)); do
    entry="$(jq -c ".[${i}]" <<<"$ANNOTATED")"
    scope="$(jq -r '.scope' <<<"$entry")"
    list="$(jq -r '.list' <<<"$entry")"
    source="$(jq -r '.source' <<<"$entry")"
    idx="$(jq -r '.index' <<<"$entry")"
    tool="$(truncate_str "$(rule_tool "$(jq -c '.rule' <<<"$entry")")" 18)"
    [ -z "$tool" ] && tool="-"
    match_sum="$(truncate_str "$(match_summary "$(jq -c '.rule' <<<"$entry")")" 40)"
    reason="$(rule_reason "$(jq -c '.rule' <<<"$entry")")"
    if [ "$use_color" -eq 1 ]; then
      color="$(color_for_list "$list")"
      printf "${color}%-8s %-6s %-9s %4s  %-18s %-40s %s${reset}\n" \
        "$scope" "$list" "$source" "$idx" "$tool" "$match_sum" "$reason"
    else
      printf '%-8s %-6s %-9s %4s  %-18s %-40s %s\n' \
        "$scope" "$list" "$source" "$idx" "$tool" "$match_sum" "$reason"
    fi
  done
}

render_grouped_table() {
  local use_color=0
  tty_color && use_color=1
  local reset=""
  [ "$use_color" -eq 1 ] && reset='\033[0m'

  # Collect unique (scope, list, source) group keys in first-seen order.
  # Using jq to compute a stable set of tuples preserving the ANNOTATED order.
  local groups
  groups="$(jq -c '
    . as $all
    | reduce range(0; length) as $i
        ({seen: {}, keys: []};
          ($all[$i] | "\(.scope)\u0001\(.list)\u0001\(.source)") as $k
          | if (.seen | has($k)) then .
            else . | .seen[$k] = true | .keys += [$k]
            end
        )
    | .keys
  ' <<<"$ANNOTATED")"

  local ngroups gi group_key scope list source color
  ngroups="$(jq -r 'length' <<<"$groups")"
  local first_group=1
  for ((gi = 0; gi < ngroups; gi++)); do
    group_key="$(jq -r ".[${gi}]" <<<"$groups")"
    scope="${group_key%%$'\x01'*}"
    local rest="${group_key#*$'\x01'}"
    list="${rest%%$'\x01'*}"
    source="${rest#*$'\x01'}"

    # Collect all annotated rules matching this group, preserving their
    # source-file index (already 1-based in .index).
    local members
    members="$(jq -c --arg s "$scope" --arg l "$list" --arg src "$source" '
      map(select(.scope == $s and .list == $l and .source == $src))
    ' <<<"$ANNOTATED")"
    local mcount
    mcount="$(jq -r 'length' <<<"$members")"
    [ "$mcount" -eq 0 ] && continue

    if [ "$first_group" -eq 0 ]; then
      printf '\n'
    fi
    first_group=0

    # Header line.
    local header_color=""
    [ "$use_color" -eq 1 ] && header_color="$(color_for_list "$list")"
    printf "${header_color}%s / %s (%s, %d rules)${reset}\n" \
      "$(printf '%s' "$scope" | tr '[:lower:]' '[:upper:]')" \
      "$list" "$source" "$mcount"

    printf '%4s  %-18s %-50s %s\n' '#' 'tool' 'match-summary' 'reason'

    local mi mentry midx mtool msum mreason
    for ((mi = 0; mi < mcount; mi++)); do
      mentry="$(jq -c ".[${mi}]" <<<"$members")"
      midx="$(jq -r '.index' <<<"$mentry")"
      mtool="$(truncate_str "$(rule_tool "$(jq -c '.rule' <<<"$mentry")")" 18)"
      [ -z "$mtool" ] && mtool="-"
      msum="$(truncate_str "$(match_summary "$(jq -c '.rule' <<<"$mentry")")" 50)"
      mreason="$(rule_reason "$(jq -c '.rule' <<<"$mentry")")"
      if [ "$use_color" -eq 1 ]; then
        color="$(color_for_list "$list")"
        printf "${color}%4s  %-18s %-50s %s${reset}\n" \
          "$midx" "$mtool" "$msum" "$mreason"
      else
        printf '%4s  %-18s %-50s %s\n' \
          "$midx" "$mtool" "$msum" "$mreason"
      fi
    done
  done
}

render_json() {
  # Output is a JSON array of annotated rule objects. `path` is included
  # so callers can see which on-disk file each rule came from.
  jq '.' <<<"$ANNOTATED"
}

render_raw() {
  # One rule JSON per line, annotation fields stripped (just the original rule).
  jq -c '.[] | .rule' <<<"$ANNOTATED"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$ARG_FORMAT" in
  table)
    if [ "$ARG_FLAT" -eq 1 ]; then
      render_flat_table
    else
      render_grouped_table
    fi
    ;;
  json)
    render_json
    ;;
  raw)
    render_raw
    ;;
esac

exit 0
