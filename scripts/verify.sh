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
# jq serializes objects with sorted keys when given `tojson` after
# `walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end)`.

canon_rule() {
  # stdin rule JSON -> stdout canonical identity string
  jq -c '{tool:(.tool // null), match:(.match // null)}
         | walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end)'
}

# Collect (canon, file, list, index) tuples for every parsed rule.
# TSV with tab separator, pipe through jq -R for canon_rule.
TUPLES_FILE="$(mktemp -t passthru-verify-tuples.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$ERRORS_FILE' '$WARNS_FILE' '$TUPLES_FILE'" EXIT

for ((fi = 0; fi < ${#PARSED_FILES[@]}; fi++)); do
  file="${PARSED_FILES[$fi]}"
  normalized="${PARSED_JSON[$fi]}"

  for list in allow deny; do
    n="$(jq -r ".${list} | length" <<<"$normalized")"
    for ((i = 0; i < n; i++)); do
      rule="$(jq -c ".${list}[$i]" <<<"$normalized")"
      canon="$(printf '%s' "$rule" | canon_rule)"
      # TSV: list, index, canon, file
      printf '%s\t%d\t%s\t%s\n' "$list" "$i" "$canon" "$file" >> "$TUPLES_FILE"
    done
  done
done

# Check 4 & 5 share a loop: for each distinct canonical rule, collect its
# (list, file) occurrences. If >1 total -> duplicate warn. If both allow and
# deny present -> conflict error.
if [ -s "$TUPLES_FILE" ]; then
  # Build a map canon -> occurrences array via awk, then post-process with jq.
  # Simpler: group by canon via sort/awk.
  sort -t $'\t' -k3,3 "$TUPLES_FILE" > "${TUPLES_FILE}.sorted"

  prev_canon=""
  group_lists=()
  group_files=()
  flush_group() {
    local canon="$prev_canon"
    [ -z "$canon" ] && return 0
    local count="${#group_lists[@]}"
    [ "$count" -le 1 ] && return 0

    # Did both allow and deny appear?
    local has_allow=0 has_deny=0
    for l in "${group_lists[@]}"; do
      case "$l" in
        allow) has_allow=1 ;;
        deny)  has_deny=1 ;;
      esac
    done

    # Build occurrence summary for the message.
    local summary=""
    for ((k = 0; k < count; k++)); do
      if [ -z "$summary" ]; then
        summary="${group_files[$k]}#${group_lists[$k]}"
      else
        summary="$summary, ${group_files[$k]}#${group_lists[$k]}"
      fi
    done

    if [ "$has_allow" = "1" ] && [ "$has_deny" = "1" ]; then
      diag error "${group_files[0]}" "" "" \
        "conflict: same tool+match appears in both allow and deny ($summary)"
    else
      diag warn "${group_files[0]}" "" "" \
        "duplicate: same rule identity appears in multiple places ($summary)"
    fi
  }

  while IFS=$'\t' read -r list idx canon file; do
    if [ "$canon" != "$prev_canon" ]; then
      flush_group
      prev_canon="$canon"
      group_lists=()
      group_files=()
    fi
    group_lists+=("$list")
    group_files+=("$file")
  done < "${TUPLES_FILE}.sorted"
  flush_group

  rm -f "${TUPLES_FILE}.sorted"
fi

# Check 6: shadowing within merged list.
# Build the post-merge allow[] and deny[] in file order.
build_merged_list() {
  # $1 = "allow" | "deny"
  local list="$1"
  local out="[]"
  for ((fi = 0; fi < ${#PARSED_FILES[@]}; fi++)); do
    local normalized="${PARSED_JSON[$fi]}"
    local chunk
    chunk="$(jq -c --arg k "$list" '.[$k]' <<<"$normalized")"
    out="$(jq -c --argjson a "$out" --argjson b "$chunk" '$a + $b' <<<'null')"
  done
  printf '%s' "$out"
}

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

if [ "${#PARSED_FILES[@]}" -gt 0 ]; then
  merged_allow="$(build_merged_list allow)"
  merged_deny="$(build_merged_list deny)"
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
