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
