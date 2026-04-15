#!/usr/bin/env bats

# tests/session_start_hook.bats
# Covers hooks/handlers/session-start.sh: the hash-diff-gated bootstrap hint.
# The hint re-fires every session until every importable entry in
# settings.json/settings.local.json is present (by _source_hash) in one of
# the passthru.imported.json files. It auto-silences when migration is
# complete.
#
# Gating matrix:
#   * no settings files                                         -> silent, no hint
#   * settings with no .permissions.allow                       -> silent, no hint
#   * settings with only non-importable entries                 -> silent, no hint
#   * settings with N importable entries, no imported file      -> hint with count N
#   * settings + legacy imported (no _source_hash fields)       -> hint with count N
#   * settings fully imported (all _source_hash present)        -> silent, no hint
#   * settings partially imported (k of N covered)              -> hint with count N-k
#   * malformed settings.json                                   -> silent, no crash
#   * malformed stdin                                           -> silent, no crash
#   * malformed imported.json                                   -> hint still fires
#   * unrelated passthru.json (authored) present                -> does not gate the hint
#
# The hash helper is `hash_settings_entry` from common.sh. Tests compute
# hashes via the same helper to keep tests and the handler in lockstep.
#
# Hermetic via PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HANDLER="$REPO_ROOT/hooks/handlers/session-start.sh"

  TMP="$(mktemp -d -t passthru-sess-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"

  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# run_handler <stdin>
# Runs the hook with the given stdin payload and captures stdout, stderr,
# and status separately so we can assert on each.
run_handler() {
  local stdin="$1"
  local tmpout tmperr
  tmpout="$(mktemp -t passthru-sess-out.XXXXXX)"
  tmperr="$(mktemp -t passthru-sess-err.XXXXXX)"
  set +e
  printf '%s' "$stdin" | bash "$HANDLER" >"$tmpout" 2>"$tmperr"
  status=$?
  set -e
  STDOUT="$(cat "$tmpout")"
  STDERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
  export status STDOUT STDERR
}

# assert_hint_envelope [expected_count]
# Verify STDOUT is a well-formed JSON object whose .systemMessage mentions
# `/passthru:bootstrap`. With an argument, also assert the count phrase.
assert_hint_envelope() {
  jq -e '.' <<<"$STDOUT" >/dev/null
  jq -e '.systemMessage | type == "string"' <<<"$STDOUT" >/dev/null
  local msg
  msg="$(jq -r '.systemMessage' <<<"$STDOUT")"
  [[ "$msg" == *"/passthru:bootstrap"* ]]
  if [ "$#" -ge 1 ]; then
    local n="$1"
    if [ "$n" -eq 1 ]; then
      [[ "$msg" == *"1 importable permission rule "* ]]
    else
      [[ "$msg" == *"$n importable permission rules "* ]]
    fi
  fi
  # Only systemMessage key.
  local keys
  keys="$(jq -r 'keys | join(",")' <<<"$STDOUT")"
  [ "$keys" = "systemMessage" ]
}

# Helpers to assemble fixture imported files with a hash per rule.
make_imported_allow_hash_only() {
  # $1 path to write, $2..$N raw entries (hashed via hash_settings_entry)
  local path="$1"; shift
  local arr="[]"
  local e h
  for e in "$@"; do
    h="$(hash_settings_entry "$e")"
    arr="$(jq -c --arg hash "$h" '. + [{tool:"Bash", match:{command:"^x$"}, reason:"t", _source_hash:$hash}]' <<<"$arr")"
  done
  jq -cn --argjson a "$arr" '{version:1, allow:$a, deny:[]}' > "$path"
}

# ---------------------------------------------------------------------------
# No settings / empty settings -> silent
# ---------------------------------------------------------------------------

@test "session-start: no settings files at all -> silent, exit 0" {
  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
}

@test "session-start: settings with empty permissions.allow -> silent, no hint" {
  printf '{"permissions":{"allow":[]}}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
}

@test "session-start: settings with no permissions key -> silent, no hint" {
  printf '{}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
}

@test "session-start: settings with only non-importable entries -> silent, no hint" {
  # ExactStrangeFormat is not recognized; bootstrap would WARN-skip.
  printf '%s\n' '{"permissions":{"allow":["ExactStrangeFormat","NotAToolRule"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
}

# ---------------------------------------------------------------------------
# Hint fires: settings has importable entries, nothing imported yet
# ---------------------------------------------------------------------------

@test "session-start: settings with N importable entries, no imported file -> hint with count" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(echo hello)","mcp__context7__query-docs"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 3
  [ -z "$STDERR" ]
}

@test "session-start: hint with singular phrasing when count is 1" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

@test "session-start: non-importable entries do NOT inflate the count" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","ExactStrangeFormat","Bash(pwd:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  # 2 importable (both Bash) + 1 skipped.
  assert_hint_envelope 2
}

# ---------------------------------------------------------------------------
# Re-fires until migration completes
# ---------------------------------------------------------------------------

@test "session-start: hint re-fires across multiple runs while imports are missing" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1

  # Second invocation - still no imported file -> still fires.
  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

# ---------------------------------------------------------------------------
# Legacy imported files (no _source_hash) -> hint still fires
# ---------------------------------------------------------------------------

@test "session-start: legacy imported file without _source_hash -> hint fires" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  # Legacy file shape: allow array with rules that lack _source_hash.
  cat > "$USER_ROOT/.claude/passthru.imported.json" <<'JSON'
{
  "version": 1,
  "allow": [{"tool":"Bash","match":{"command":"^ls(\\s|$)"},"reason":"legacy"}],
  "deny": []
}
JSON

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

# ---------------------------------------------------------------------------
# Fully covered: settings all imported -> silent
# ---------------------------------------------------------------------------

@test "session-start: settings fully covered by imported _source_hash -> silent, no hint" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(echo hello)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  make_imported_allow_hash_only \
    "$USER_ROOT/.claude/passthru.imported.json" \
    'Bash(ls:*)' \
    'Bash(echo hello)'

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
}

@test "session-start: partial coverage -> hint fires with remaining count" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(pwd:*)","Bash(echo ok)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  # Only Bash(ls:*) imported.
  make_imported_allow_hash_only \
    "$USER_ROOT/.claude/passthru.imported.json" \
    'Bash(ls:*)'

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 2
}

@test "session-start: project-scope imported coverage silences the hint" {
  # User settings has entries; project imported.json covers them all.
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  make_imported_allow_hash_only \
    "$PROJ_ROOT/.claude/passthru.imported.json" \
    'Bash(ls:*)'

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
}

# ---------------------------------------------------------------------------
# Authored passthru.json does NOT gate the hint (that was the old behavior).
# ---------------------------------------------------------------------------

@test "session-start: authored passthru.json does not gate the hint" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  # User hand-authored a rule (unrelated to the importable entry).
  cat > "$USER_ROOT/.claude/passthru.json" <<'JSON'
{
  "version": 1,
  "allow": [{"tool":"^Bash$","match":{"command":"^make\\b"},"reason":"hand"}],
  "deny": []
}
JSON

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

# ---------------------------------------------------------------------------
# Project-scope settings contribute too
# ---------------------------------------------------------------------------

@test "session-start: project settings entries count toward the hint" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

@test "session-start: project settings.local.json entries count toward the hint" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.local.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

@test "session-start: identical entries in multiple settings files dedup to one hash" {
  # Same entry in user and project settings -> one hash, count 1.
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

# ---------------------------------------------------------------------------
# Malformed inputs -> fail open, no crash
# ---------------------------------------------------------------------------

@test "session-start: malformed stdin -> exit 0, hint still fires if conditions met" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler 'not-json{{{'
  [ "$status" -eq 0 ]
  # stdin is /dev/null'd, so the hint still fires.
  assert_hint_envelope 1
}

@test "session-start: empty stdin -> exit 0, hint fires if conditions met" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler ''
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

@test "session-start: malformed settings.json -> silent, no crash" {
  printf 'not-json{' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
}

@test "session-start: malformed imported.json -> hint still fires (treated as empty)" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  printf 'not-json{' > "$USER_ROOT/.claude/passthru.imported.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  # imported yields no hashes, so the settings hash is un-covered.
  assert_hint_envelope 1
}

# ---------------------------------------------------------------------------
# Legacy marker file - no longer used
# ---------------------------------------------------------------------------

@test "session-start: legacy marker file does NOT suppress the hint" {
  # Old behavior: marker gated the hint. New behavior: the marker is ignored.
  touch "$USER_ROOT/.claude/passthru.bootstrap-hint-shown"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  assert_hint_envelope 1
}

@test "session-start: handler does not create the legacy marker file" {
  # Confirms the old marker-touch logic is gone.
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ ! -e "$USER_ROOT/.claude/passthru.bootstrap-hint-shown" ]
}
