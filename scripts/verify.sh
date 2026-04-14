#!/usr/bin/env bash
# claude-passthru rule verifier.
#
# Checks every known rule file (user-authored, user-imported, project-authored,
# project-imported) for correctness in one pass. Invoked automatically by
# scripts/write-rule.sh after every LLM- or bootstrap-driven rule write, and
# manually via /passthru:verify.
#
# Checks (across the merged set):
#   1. parse      - every existing file parses as JSON.
#   2. schema     - each rule has `tool` or `match`; types match spec; version: 1.
#   3. regex      - every `tool` regex and every `match.*` regex compiles in perl.
#   4. duplicates - exact-duplicate rules (same tool + match) across scopes -> warn.
#   5. conflict   - identical tool + match in both allow[] and deny[] -> error.
#   6. shadowing  - within one post-merge allow[] or deny[] array, index j<i with
#                   identical tool+match as index i -> warn.
#
# Flags:
#   --strict          warnings also trigger non-zero exit (exit 2 instead of 0).
#   --quiet           no stdout on success; errors still print to stderr.
#   --scope SCOPE     user|project|all (default all).
#   --format FMT      plain|json (default plain).
#
# Exit codes:
#   0 clean
#   1 any error
#   2 warnings only (only if --strict)
#
# Report format:
#   success (plain): `[OK] N rules across M files checked`
#   failure (plain): `<severity> <file>:<jq-path> [rule-index] <message>`
#   success (json) : `{"status":"ok","rules":N,"files":M,"errors":[],"warnings":[]}`
#   failure (json) : `{"status":"error|warn","rules":N,"files":M,"errors":[...],"warnings":[...]}`
#
# Paths honor PASSTHRU_USER_HOME + PASSTHRU_PROJECT_DIR for isolated tests.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate and source common.sh
# ---------------------------------------------------------------------------
# Prefer $CLAUDE_PLUGIN_ROOT when Claude Code sets it; fall back to a path
# relative to this script so standalone CLI + bats test invocations work.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/common.sh"
else
  _PASSTHRU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_COMMON="${_PASSTHRU_SCRIPT_DIR}/../hooks/common.sh"
  if [ ! -f "$_PASSTHRU_COMMON" ]; then
    printf '[passthru] fatal: cannot locate common.sh (tried $CLAUDE_PLUGIN_ROOT and %s)\n' \
      "$_PASSTHRU_COMMON" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$_PASSTHRU_COMMON"
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

STRICT=0
QUIET=0
SCOPE="all"
FORMAT="plain"

print_usage() {
  cat <<'USAGE'
usage: verify.sh [--strict] [--quiet] [--scope user|project|all] [--format plain|json]

Validates claude-passthru rule files across user and project scopes.
Exit 0 on clean, 1 on errors, 2 on warnings (with --strict only).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --quiet)  QUIET=1; shift ;;
    --scope)
      shift
      [ $# -gt 0 ] || { printf 'verify.sh: --scope requires a value\n' >&2; exit 1; }
      SCOPE="$1"; shift
      ;;
    --scope=*) SCOPE="${1#--scope=}"; shift ;;
    --format)
      shift
      [ $# -gt 0 ] || { printf 'verify.sh: --format requires a value\n' >&2; exit 1; }
      FORMAT="$1"; shift
      ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    -h|--help) print_usage; exit 0 ;;
    --) shift; break ;;
    *)
      printf 'verify.sh: unknown argument: %s\n' "$1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

case "$SCOPE" in
  user|project|all) ;;
  *) printf 'verify.sh: invalid --scope: %s (want user|project|all)\n' "$SCOPE" >&2; exit 1 ;;
esac

case "$FORMAT" in
  plain|json) ;;
  *) printf 'verify.sh: invalid --format: %s (want plain|json)\n' "$FORMAT" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Build the file list according to --scope
# ---------------------------------------------------------------------------

FILES=()
case "$SCOPE" in
  user|all)
    FILES+=("$(passthru_user_authored_path)")
    FILES+=("$(passthru_user_imported_path)")
    ;;
esac
case "$SCOPE" in
  project|all)
    FILES+=("$(passthru_project_authored_path)")
    FILES+=("$(passthru_project_imported_path)")
    ;;
esac

# Filter to existing files only.
EXISTING=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] && EXISTING+=("$f")
done

# ---------------------------------------------------------------------------
# Diagnostics buffers (one JSON line per entry for simple serialization)
# ---------------------------------------------------------------------------

ERRORS_FILE="$(mktemp -t passthru-verify-err.XXXXXX)"
WARNS_FILE="$(mktemp -t passthru-verify-warn.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$ERRORS_FILE' '$WARNS_FILE'" EXIT

# diag <severity> <file> <jq_path> <rule_index_or_empty> <message>
# severity: error|warn
diag() {
  local sev="$1" file="$2" path="$3" idx="$4" msg="$5"
  local line
  line="$(jq -cn \
    --arg sev "$sev" \
    --arg file "$file" \
    --arg path "$path" \
    --arg idx "$idx" \
    --arg msg "$msg" \
    '{severity:$sev, file:$file, path:$path, rule_index:(if $idx == "" then null else ($idx|tonumber) end), message:$msg}')"
  case "$sev" in
    error) printf '%s\n' "$line" >> "$ERRORS_FILE" ;;
    warn)  printf '%s\n' "$line" >> "$WARNS_FILE" ;;
  esac
}

# ---------------------------------------------------------------------------
# Check 1: parse
# ---------------------------------------------------------------------------
# Also populates two parallel arrays: PARSED_FILES and PARSED_JSON (one normalized
# object per file). Parse failures are reported and the file is excluded from
# downstream checks.

PARSED_FILES=()
PARSED_JSON=()

for f in "${EXISTING[@]}"; do
  if [ ! -s "$f" ]; then
    # Empty file -> treat as {}.
    PARSED_FILES+=("$f")
    PARSED_JSON+=('{"version":1,"allow":[],"deny":[]}')
    continue
  fi
  jq_err=""
  if ! jq_err="$(jq -e '.' "$f" 2>&1 >/dev/null)"; then
    diag error "$f" "" "" "parse: $jq_err"
    continue
  fi
  normalized="$(jq -c '{version:(.version // 1), allow:(.allow // []), deny:(.deny // [])}' "$f" 2>/dev/null || echo '')"
  if [ -z "$normalized" ]; then
    diag error "$f" "" "" "parse: normalization failed"
    continue
  fi
  PARSED_FILES+=("$f")
  PARSED_JSON+=("$normalized")
done

# ---------------------------------------------------------------------------
# Helper: regex_compile <pattern> -> 0 ok, 2 bad, stderr carries perl's error
# ---------------------------------------------------------------------------
# perl qr// compiles the pattern without matching anything.
regex_compile() {
  local pat="$1"
  perl -e '
    my $p = $ARGV[0];
    my $q = eval { qr/$p/ };
    if ($@) { print STDERR $@; exit 2; }
    exit 0;
  ' "$pat"
}

# ---------------------------------------------------------------------------
# Per-file checks: schema + regex compile
# ---------------------------------------------------------------------------
# For every parsed file, iterate .allow[] and .deny[] and validate each rule.

check_rule() {
  # $1 file, $2 list (allow|deny), $3 rule_json, $4 index
  local file="$1" list="$2" rule="$3" idx="$4"
  local has_tool has_match tool_type match_type

  has_tool="$(jq -r 'has("tool")' <<<"$rule")"
  has_match="$(jq -r 'has("match")' <<<"$rule")"

  # Schema: must have tool or match.
  if [ "$has_tool" != "true" ] && [ "$has_match" != "true" ]; then
    diag error "$file" ".${list}[${idx}]" "$idx" 'schema: rule must have at least one of "tool" or "match"'
    return 0
  fi

  # Tool field: string, non-empty, compiles as regex.
  if [ "$has_tool" = "true" ]; then
    tool_type="$(jq -r '.tool | type' <<<"$rule")"
    if [ "$tool_type" != "string" ]; then
      diag error "$file" ".${list}[${idx}].tool" "$idx" "schema: .tool must be string (got $tool_type)"
    else
      local tool_pat
      tool_pat="$(jq -r '.tool' <<<"$rule")"
      if [ -z "$tool_pat" ]; then
        diag error "$file" ".${list}[${idx}].tool" "$idx" "schema: .tool must be non-empty"
      else
        local re_err
        if ! re_err="$(regex_compile "$tool_pat" 2>&1)"; then
          # Compact perl's error to a single line.
          re_err="$(printf '%s' "$re_err" | head -n 1 | tr -d '\n')"
          diag error "$file" ".${list}[${idx}].tool" "$idx" "regex: invalid pattern '$tool_pat': $re_err"
        fi
      fi
    fi
  fi

  # Match field: object; every value is non-empty string that compiles.
  if [ "$has_match" = "true" ]; then
    match_type="$(jq -r '.match | type' <<<"$rule")"
    if [ "$match_type" != "object" ]; then
      diag error "$file" ".${list}[${idx}].match" "$idx" "schema: .match must be object (got $match_type)"
    else
      # Iterate keys.
      local match_pairs key val val_type re_err
      while IFS= read -r key; do
        [ -z "$key" ] && continue
        val_type="$(jq -r --arg k "$key" '.match[$k] | type' <<<"$rule")"
        if [ "$val_type" != "string" ]; then
          diag error "$file" ".${list}[${idx}].match.${key}" "$idx" \
            "schema: match value must be string (got $val_type)"
          continue
        fi
        val="$(jq -r --arg k "$key" '.match[$k]' <<<"$rule")"
        if [ -z "$val" ]; then
          diag error "$file" ".${list}[${idx}].match.${key}" "$idx" \
            "schema: match value must be non-empty"
          continue
        fi
        if ! re_err="$(regex_compile "$val" 2>&1)"; then
          re_err="$(printf '%s' "$re_err" | head -n 1 | tr -d '\n')"
          diag error "$file" ".${list}[${idx}].match.${key}" "$idx" \
            "regex: invalid pattern '$val': $re_err"
        fi
      done < <(jq -r '.match | keys_unsorted[]' <<<"$rule")
    fi
  fi
}

TOTAL_RULES=0
# Iterate parsed files and their rules.
for ((fi = 0; fi < ${#PARSED_FILES[@]}; fi++)); do
  file="${PARSED_FILES[$fi]}"
  normalized="${PARSED_JSON[$fi]}"

  # Version check: if original file had .version and it's not 1, fail.
  # Empty files are normalized to version 1 by PARSED_JSON above, so read from
  # the normalized JSON rather than the raw file.
  ver="$(jq -r '.version // 1' <<<"$normalized")"
  if [ "$ver" != "1" ]; then
    diag error "$file" ".version" "" "schema: unsupported version $ver (expected 1)"
  fi

  # Allow[] rules.
  n_allow="$(jq -r '.allow | length' <<<"$normalized")"
  for ((i = 0; i < n_allow; i++)); do
    rule="$(jq -c ".allow[$i]" <<<"$normalized")"
    check_rule "$file" "allow" "$rule" "$i"
    TOTAL_RULES=$((TOTAL_RULES + 1))
  done

  # Deny[] rules.
  n_deny="$(jq -r '.deny | length' <<<"$normalized")"
  for ((i = 0; i < n_deny; i++)); do
    rule="$(jq -c ".deny[$i]" <<<"$normalized")"
    check_rule "$file" "deny" "$rule" "$i"
    TOTAL_RULES=$((TOTAL_RULES + 1))
  done
done

# ---------------------------------------------------------------------------
# Check 4: duplicates (across scopes)
# Check 5: deny/allow conflict (across scopes)
# Check 6: shadowing (within merged list)
# ---------------------------------------------------------------------------
#
# Normalized rule identity: {tool, match} only. Reason/other fields do not count.
# jq serializes objects with sorted keys when given `tojson` after a recursive
# key-sort walk.
#
# We compute everything in a single `jq -s` invocation that consumes a JSON
# array of {file, list, index, canon, allow_chunk, deny_chunk} records and
# emits the merged allow[]/deny[] arrays plus the duplicate/conflict groups.
# This replaces ~80 lines of bash sort + flush_group + per-file merge loops.

canon_rule() {
  # stdin rule JSON -> stdout canonical identity string
  jq -c '{tool:(.tool // null), match:(.match // null)}
         | walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end)'
}

# Build a JSON array of file documents, each with its parsed rules and the
# file path. Feed everything to jq once.
PER_FILE_INPUTS="["
for ((fi = 0; fi < ${#PARSED_FILES[@]}; fi++)); do
  [ "$fi" -gt 0 ] && PER_FILE_INPUTS+=","
  PER_FILE_INPUTS+="$(jq -cn \
    --arg file "${PARSED_FILES[$fi]}" \
    --argjson doc "${PARSED_JSON[$fi]}" \
    '{file:$file, doc:$doc}')"
done
PER_FILE_INPUTS+="]"

if [ "${#PARSED_FILES[@]}" -gt 0 ]; then
  # Single pipeline computes:
  #   .duplicates : array of {canon, occurrences:[{file,list,index},...]}
  #                 with len > 1 (group_by(canon))
  #   .merged_allow / .merged_deny : concatenated lists (file order, then index)
  GROUP_REPORT="$(jq -c '
    def canon: {tool:(.tool // null), match:(.match // null)}
               | walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end)
               | tojson;
    . as $files
    | (reduce range(0; $files | length) as $fi
        ([];
          . + ([range(0; ($files[$fi].doc.allow | length)) as $i
            | { file: $files[$fi].file, list: "allow", index: $i,
                rule: ($files[$fi].doc.allow[$i]) }])
          + ([range(0; ($files[$fi].doc.deny | length)) as $i
            | { file: $files[$fi].file, list: "deny", index: $i,
                rule: ($files[$fi].doc.deny[$i]) }])
        )
      ) as $tuples
    | {
        duplicates:
          ($tuples
           | map(. + {canon: (.rule | canon)})
           | group_by(.canon)
           | map({ canon: .[0].canon,
                   occurrences: map({file, list, index}) })
           | map(select(.occurrences | length > 1))),
        merged_allow:
          ($files | map(.doc.allow) | add // []),
        merged_deny:
          ($files | map(.doc.deny) | add // [])
      }
  ' <<<"$PER_FILE_INPUTS")"

  # Walk the duplicate groups: classify each as conflict (allow + deny) or
  # plain duplicate (same list, multiple times).
  while IFS= read -r group; do
    [ -z "$group" ] && continue
    has_allow="$(jq -r '.occurrences | map(select(.list == "allow")) | length > 0' <<<"$group")"
    has_deny="$(jq -r '.occurrences | map(select(.list == "deny")) | length > 0' <<<"$group")"
    summary="$(jq -r '.occurrences | map("\(.file)#\(.list)") | join(", ")' <<<"$group")"
    first_file="$(jq -r '.occurrences[0].file' <<<"$group")"
    if [ "$has_allow" = "true" ] && [ "$has_deny" = "true" ]; then
      diag error "$first_file" "" "" \
        "conflict: same tool+match appears in both allow and deny ($summary)"
    else
      diag warn "$first_file" "" "" \
        "duplicate: same rule identity appears in multiple places ($summary)"
    fi
  done < <(jq -c '.duplicates[]' <<<"$GROUP_REPORT")
fi

# Check 6: shadowing within the merged list. Reuses the merged_allow /
# merged_deny arrays we just built (zero extra jq forks per file).
check_shadowing_in_list() {
  # $1 = list name (for message), $2 = merged JSON array
  # Build canonical identity strings for every entry once (one jq fork per
  # rule), then compare by index. Old behaviour was O(N^2) jq forks; this is
  # O(N) jq forks plus O(N^2) bash string compares (cheap).
  local list="$1" arr="$2"
  local n
  n="$(jq -r 'length' <<<"$arr")"
  [ "$n" -le 1 ] && return 0

  local i j
  local canon_arr=()
  for ((i = 0; i < n; i++)); do
    canon_arr[$i]="$(jq -c ".[$i]" <<<"$arr" | canon_rule)"
  done

  for ((i = 1; i < n; i++)); do
    for ((j = 0; j < i; j++)); do
      if [ "${canon_arr[$i]}" = "${canon_arr[$j]}" ]; then
        diag warn "(merged-$list)" ".${list}[${i}]" "$i" \
          "shadowing: rule $i shadowed by earlier identical rule at index $j"
        break
      fi
    done
  done
}

if [ "${#PARSED_FILES[@]}" -gt 0 ] && [ -n "${GROUP_REPORT:-}" ]; then
  merged_allow="$(jq -c '.merged_allow' <<<"$GROUP_REPORT")"
  merged_deny="$(jq -c '.merged_deny'  <<<"$GROUP_REPORT")"
  check_shadowing_in_list allow "$merged_allow"
  check_shadowing_in_list deny "$merged_deny"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

ERR_COUNT=0
WARN_COUNT=0
[ -s "$ERRORS_FILE" ] && ERR_COUNT="$(wc -l < "$ERRORS_FILE" | tr -d ' ')"
[ -s "$WARNS_FILE" ]  && WARN_COUNT="$(wc -l < "$WARNS_FILE"  | tr -d ' ')"

M_FILES="${#EXISTING[@]}"

if [ "$FORMAT" = "json" ]; then
  # Build a JSON report.
  errs_arr="[]"
  warns_arr="[]"
  [ -s "$ERRORS_FILE" ] && errs_arr="$(jq -s '.' "$ERRORS_FILE")"
  [ -s "$WARNS_FILE" ]  && warns_arr="$(jq -s '.' "$WARNS_FILE")"
  status="ok"
  if [ "$ERR_COUNT" -gt 0 ]; then
    status="error"
  elif [ "$WARN_COUNT" -gt 0 ]; then
    status="warn"
  fi
  jq -cn \
    --arg status "$status" \
    --argjson rules "$TOTAL_RULES" \
    --argjson files "$M_FILES" \
    --argjson errors "$errs_arr" \
    --argjson warnings "$warns_arr" \
    '{status:$status, rules:$rules, files:$files, errors:$errors, warnings:$warnings}'
else
  # Plain format.
  if [ "$ERR_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    if [ "$M_FILES" -eq 0 ]; then
      [ "$QUIET" -eq 0 ] && printf '[OK] no rules (no passthru files found)\n'
    else
      [ "$QUIET" -eq 0 ] && printf '[OK] %d rules across %d files checked\n' "$TOTAL_RULES" "$M_FILES"
    fi
  else
    # Print each entry in the `<severity> <file>:<jq-path> [rule-index] <message>` form.
    if [ -s "$ERRORS_FILE" ]; then
      while IFS= read -r entry; do
        sev="$(jq -r '.severity' <<<"$entry")"
        file="$(jq -r '.file' <<<"$entry")"
        path="$(jq -r '.path' <<<"$entry")"
        idx="$(jq -r '.rule_index // "" | tostring' <<<"$entry")"
        msg="$(jq -r '.message' <<<"$entry")"
        idx_fmt=""
        [ -n "$idx" ] && [ "$idx" != "null" ] && idx_fmt=" [rule $idx]"
        path_fmt=""
        [ -n "$path" ] && path_fmt=":$path"
        printf '[ERR] %s%s%s %s\n' "$file" "$path_fmt" "$idx_fmt" "$msg" >&2
      done < "$ERRORS_FILE"
    fi
    if [ -s "$WARNS_FILE" ]; then
      while IFS= read -r entry; do
        file="$(jq -r '.file' <<<"$entry")"
        path="$(jq -r '.path' <<<"$entry")"
        idx="$(jq -r '.rule_index // "" | tostring' <<<"$entry")"
        msg="$(jq -r '.message' <<<"$entry")"
        idx_fmt=""
        [ -n "$idx" ] && [ "$idx" != "null" ] && idx_fmt=" [rule $idx]"
        path_fmt=""
        [ -n "$path" ] && path_fmt=":$path"
        if [ "$QUIET" -eq 0 ] || [ "$STRICT" -eq 1 ]; then
          # On --strict, surface warnings to stderr so callers see them even in quiet mode.
          if [ "$STRICT" -eq 1 ] && [ "$QUIET" -eq 1 ]; then
            printf '[WARN] %s%s%s %s\n' "$file" "$path_fmt" "$idx_fmt" "$msg" >&2
          else
            printf '[WARN] %s%s%s %s\n' "$file" "$path_fmt" "$idx_fmt" "$msg"
          fi
        fi
      done < "$WARNS_FILE"
    fi
  fi
fi

# Exit code selection.
if [ "$ERR_COUNT" -gt 0 ]; then
  exit 1
fi
if [ "$WARN_COUNT" -gt 0 ] && [ "$STRICT" -eq 1 ]; then
  exit 2
fi
exit 0
