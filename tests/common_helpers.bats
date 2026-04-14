#!/usr/bin/env bats

# tests/common_helpers.bats
# Direct unit tests for the small helper functions exposed by hooks/common.sh.
# These helpers are exercised end-to-end in other suites, but the most
# security-relevant one (sanitize_tool_use_id) deserves dedicated assertions
# spanning the full input matrix it has to handle.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  TMP="$(mktemp -d -t passthru-helpers.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"
  export TMPDIR="$TMP/tmp"
  mkdir -p "$TMPDIR"

  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# sanitize_tool_use_id - path-traversal guard
# ---------------------------------------------------------------------------

@test "sanitize_tool_use_id: path traversal '../../etc/abc' -> 'etcabc'" {
  result="$(sanitize_tool_use_id '../../etc/abc')"
  [ "$result" = "etcabc" ]
}

@test "sanitize_tool_use_id: empty input -> empty output" {
  result="$(sanitize_tool_use_id '')"
  [ -z "$result" ]
}

@test "sanitize_tool_use_id: single slash 'a/b' -> 'ab'" {
  result="$(sanitize_tool_use_id 'a/b')"
  [ "$result" = "ab" ]
}

@test "sanitize_tool_use_id: bare '..' -> empty (every char stripped)" {
  result="$(sanitize_tool_use_id '..')"
  [ -z "$result" ]
}

@test "sanitize_tool_use_id: legitimate id passes through unchanged" {
  result="$(sanitize_tool_use_id 'abc-def_ghi123')"
  [ "$result" = "abc-def_ghi123" ]
}

@test "sanitize_tool_use_id: shell metacharacters are stripped" {
  # ; & | $ () < > " ' \ etc. would all be hazardous if they leaked into a
  # path. Only [A-Za-z0-9_-] survives.
  result="$(sanitize_tool_use_id 'abc;rm -rf $HOME')"
  [ "$result" = "abcrm-rfHOME" ]
}

@test "sanitize_tool_use_id: unicode and control chars stripped" {
  # Non-ASCII bytes (e.g. accented chars) and control chars must not land
  # in a filename.
  result="$(sanitize_tool_use_id $'abc\x01\x02def')"
  [ "$result" = "abcdef" ]
}

# ---------------------------------------------------------------------------
# passthru_user_home
# ---------------------------------------------------------------------------

@test "passthru_user_home: honors PASSTHRU_USER_HOME override" {
  result="$(passthru_user_home)"
  [ "$result" = "$USER_ROOT" ]
}

@test "passthru_user_home: falls back to \$HOME when override unset" {
  unset PASSTHRU_USER_HOME
  HOME=/some/fake/home
  result="$(passthru_user_home)"
  [ "$result" = "/some/fake/home" ]
}

# ---------------------------------------------------------------------------
# passthru_tmpdir
# ---------------------------------------------------------------------------

@test "passthru_tmpdir: honors TMPDIR" {
  result="$(passthru_tmpdir)"
  [ "$result" = "$TMPDIR" ]
}

@test "passthru_tmpdir: falls back to /tmp when TMPDIR unset" {
  unset TMPDIR
  result="$(passthru_tmpdir)"
  [ "$result" = "/tmp" ]
}

# ---------------------------------------------------------------------------
# passthru_iso_ts
# ---------------------------------------------------------------------------

@test "passthru_iso_ts: emits ISO 8601 Z form" {
  result="$(passthru_iso_ts)"
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ---------------------------------------------------------------------------
# passthru_sha256
# ---------------------------------------------------------------------------

@test "passthru_sha256: missing file -> empty output (no error)" {
  result="$(passthru_sha256 "$TMP/does-not-exist")"
  [ -z "$result" ]
}

@test "passthru_sha256: known content -> stable hex digest" {
  printf 'hello' > "$TMP/probe"
  result="$(passthru_sha256 "$TMP/probe")"
  # sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
  [ "$result" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

# ---------------------------------------------------------------------------
# audit_enabled / audit_log_path
# ---------------------------------------------------------------------------

@test "audit_enabled: 1 (false) when sentinel missing" {
  run audit_enabled
  [ "$status" -eq 1 ]
}

@test "audit_enabled: 0 (true) when sentinel present" {
  touch "$USER_ROOT/.claude/passthru.audit.enabled"
  run audit_enabled
  [ "$status" -eq 0 ]
}

@test "audit_log_path: resolves under PASSTHRU_USER_HOME" {
  result="$(audit_log_path)"
  [ "$result" = "$USER_ROOT/.claude/passthru-audit.log" ]
}

# ---------------------------------------------------------------------------
# emit_passthrough
# ---------------------------------------------------------------------------

@test "emit_passthrough: prints canonical JSON envelope + newline" {
  result="$(emit_passthrough)"
  [ "$result" = '{"continue": true}' ]
  # And must be valid JSON.
  run jq -e '.continue == true' <<<"$result"
  [ "$status" -eq 0 ]
}
