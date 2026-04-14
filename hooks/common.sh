#!/usr/bin/env bash
# claude-passthru common library, sourced by hook handlers and scripts.
# Provides rule file loading, merging, and basic schema validation.
#
# Functions:
#   load_rules                 - read + merge up to four rule files, emit JSON on stdout.
#   validate_rules <json>      - schema-validate merged JSON, exit nonzero with message on violation.
#
# All output is plain ASCII. Errors go to stderr. Functions return non-zero on failure
# without calling `exit` so callers can decide how to recover (hook handler fails open,
# verifier fails closed).

# Intentionally NOT setting `set -e` here. Callers decide error handling.
# This file is sourced, not executed.

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
#   { "version": 1, "allow": [...], "deny": [...] }
# where allow[] and deny[] are concatenated in this fixed order:
#   user-authored, user-imported, project-authored, project-imported.
# Ordering matters for shadowing reports and for first-match semantics.
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
  # Each element becomes a JSON object with .allow[] and .deny[] (possibly empty).
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
    # Normalize: ensure .allow and .deny exist as arrays.
    if ! jq '{ version: (.version // 1), allow: (.allow // []), deny: (.deny // []) }' \
        "$f" > "${tmpdir}/${idx}.json" 2>"${tmpdir}/err"; then
      printf '[ERR] failed to normalize %s: %s\n' "$f" "$(cat "${tmpdir}/err")" >&2
      return 2
    fi
    idx=$((idx + 1))
  done

  # Merge: concat allow[] and deny[] across all inputs, preserve order.
  # If no files at all, emit empty skeleton.
  if [ "$idx" -eq 0 ]; then
    printf '{"version":1,"allow":[],"deny":[]}\n'
    return 0
  fi

  local inputs=()
  local i
  for ((i = 0; i < idx; i++)); do
    inputs+=("${tmpdir}/${i}.json")
  done

  jq -s '{
    version: 1,
    allow: ([.[].allow // []] | add),
    deny: ([.[].deny // []] | add)
  }' "${inputs[@]}"
}

# ---------------------------------------------------------------------------
# validate_rules
# ---------------------------------------------------------------------------
#
# Usage: validate_rules <merged-json>
# Enforces:
#   - top-level .version is 1 (if present, must be 1; absent = ok, merged output always sets 1)
#   - .allow and .deny are arrays (possibly empty)
#   - each rule object has at least one of "tool" or "match"
#   - if present, .tool is a non-empty string
#   - if present, .match is an object and every value is a non-empty string
# Does NOT compile-check PCRE at load time (per plan: deep regex checks live in verify.sh).
# Returns 0 if valid, nonzero with stderr message otherwise.
validate_rules() {
  local merged="$1"
  if [ -z "$merged" ]; then
    printf '[ERR] validate_rules: empty input\n' >&2
    return 2
  fi

  # Version check: if .version is present and not 1, reject.
  local ver
  ver="$(jq -r '.version // 1' <<<"$merged" 2>/dev/null)"
  if [ "$ver" != "1" ]; then
    printf '[ERR] unsupported rule schema version: %s (expected 1)\n' "$ver" >&2
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

  # Per-rule schema checks for both arrays.
  local report
  report="$(jq -r '
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
    ( (.deny  // []) | to_entries[] | check_rule("deny") )
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
