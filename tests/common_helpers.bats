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

# ---------------------------------------------------------------------------
# is_importable_entry
# ---------------------------------------------------------------------------
# Single source of truth for "would bootstrap.sh convert this entry?". Must
# stay in lockstep with scripts/bootstrap.sh's convert_rule.

@test "is_importable_entry: Bash prefix form is importable" {
  run is_importable_entry 'Bash(ls:*)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: Bash empty prefix is NOT importable" {
  run is_importable_entry 'Bash(:*)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Bash exact command is importable" {
  run is_importable_entry 'Bash(echo hello)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: Bash with embedded newline is NOT importable" {
  run is_importable_entry $'Bash(line1\nline2)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: WebFetch(domain:...) is importable" {
  run is_importable_entry 'WebFetch(domain:x.com)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: WebFetch with empty domain is NOT importable" {
  run is_importable_entry 'WebFetch(domain:)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: WebFetch(other:...) is NOT importable" {
  run is_importable_entry 'WebFetch(notdomain:x.com)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: bare WebSearch is importable" {
  run is_importable_entry 'WebSearch'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: mcp__ identifier is importable" {
  run is_importable_entry 'mcp__context7__query-docs'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: mcp__ with parens is NOT importable" {
  run is_importable_entry 'mcp__foo(arg)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Read(<path>) is importable" {
  run is_importable_entry 'Read(/etc/hosts)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: Read(<path>/**) is importable" {
  run is_importable_entry 'Read(/var/log/**)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: Read(~/foo) is importable" {
  run is_importable_entry 'Read(~/foo)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: Read(~user/...) is NOT importable" {
  run is_importable_entry 'Read(~user/x)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Read(\$HOME/...) is NOT importable" {
  run is_importable_entry 'Read($HOME/x)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Read(%APPDATA%) is NOT importable" {
  run is_importable_entry 'Read(%APPDATA%)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Read(=cmd) is NOT importable" {
  run is_importable_entry 'Read(=cmd)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Read(\\\\server\\share) is NOT importable" {
  run is_importable_entry 'Read(\\server\share)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Edit and Write follow the same path checks" {
  run is_importable_entry 'Edit(/var/log/app.log)'
  [ "$status" -eq 0 ]
  run is_importable_entry 'Write(/tmp/out/**)'
  [ "$status" -eq 0 ]
  run is_importable_entry 'Edit($HOME/x)'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: Skill(<name>) is importable" {
  run is_importable_entry 'Skill(revdiff)'
  [ "$status" -eq 0 ]
}

@test "is_importable_entry: Skill() empty name is NOT importable" {
  run is_importable_entry 'Skill()'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: unknown format is NOT importable" {
  run is_importable_entry 'ExactStrangeFormat'
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: empty input is NOT importable" {
  run is_importable_entry ''
  [ "$status" -eq 1 ]
}

@test "is_importable_entry: leading/trailing whitespace is trimmed before classification" {
  run is_importable_entry '   Bash(ls:*)   '
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# normalize_settings_entry
# ---------------------------------------------------------------------------

@test "normalize_settings_entry: strips leading and trailing whitespace" {
  result="$(normalize_settings_entry '   Bash(ls:*)   ')"
  [ "$result" = 'Bash(ls:*)' ]
}

@test "normalize_settings_entry: does not lowercase (CC parser is case-sensitive)" {
  result="$(normalize_settings_entry 'Bash(LS:*)')"
  [ "$result" = 'Bash(LS:*)' ]
}

@test "normalize_settings_entry: preserves inner whitespace" {
  result="$(normalize_settings_entry 'Bash(git status:*)')"
  [ "$result" = 'Bash(git status:*)' ]
}

# ---------------------------------------------------------------------------
# hash_settings_entry
# ---------------------------------------------------------------------------

@test "hash_settings_entry: same normalized input yields same hash" {
  a="$(hash_settings_entry 'Bash(ls:*)')"
  b="$(hash_settings_entry '   Bash(ls:*)  ')"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "hash_settings_entry: case-sensitive (Bash != bash)" {
  a="$(hash_settings_entry 'Bash(ls:*)')"
  b="$(hash_settings_entry 'bash(ls:*)')"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" != "$b" ]
}

@test "hash_settings_entry: different entries yield different hashes" {
  a="$(hash_settings_entry 'Bash(ls:*)')"
  b="$(hash_settings_entry 'Bash(echo hello)')"
  [ "$a" != "$b" ]
}

@test "hash_settings_entry: output is 64-char lowercase hex (sha256)" {
  result="$(hash_settings_entry 'Bash(ls:*)')"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]]
}

# ---------------------------------------------------------------------------
# settings_importable_hashes
# ---------------------------------------------------------------------------

@test "settings_importable_hashes: no files -> empty output" {
  result="$(settings_importable_hashes)"
  [ -z "$result" ]
}

@test "settings_importable_hashes: emits one hash per importable entry" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(echo hi)","mcp__x__y"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  result="$(settings_importable_hashes | sort)"
  expected="$({ hash_settings_entry 'Bash(ls:*)'; hash_settings_entry 'Bash(echo hi)'; hash_settings_entry 'mcp__x__y'; } | sort)"
  [ "$result" = "$expected" ]
}

@test "settings_importable_hashes: non-importable entries are filtered out" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","ExactStrangeFormat","Bash(pwd:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  lines="$(settings_importable_hashes | grep -c '.')"
  [ "$lines" = "2" ]
}

@test "settings_importable_hashes: project shared + local + user all contribute" {
  printf '%s\n' '{"permissions":{"allow":["Bash(a:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(b:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(c:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.local.json"
  lines="$(settings_importable_hashes | sort -u | grep -c '.')"
  [ "$lines" = "3" ]
}

@test "settings_importable_hashes: malformed settings file is silently skipped" {
  printf 'not-json{' > "$USER_ROOT/.claude/settings.json"
  result="$(settings_importable_hashes)"
  [ -z "$result" ]
}

@test "settings_importable_hashes: non-string entries are filtered by jq" {
  # Mixed string + object entries: object is ignored, strings processed.
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)",{"unexpected":"object"}]}}' \
    > "$USER_ROOT/.claude/settings.json"
  lines="$(settings_importable_hashes | grep -c '.')"
  [ "$lines" = "1" ]
}

# ---------------------------------------------------------------------------
# imported_hashes
# ---------------------------------------------------------------------------

@test "imported_hashes: no files -> empty output" {
  result="$(imported_hashes)"
  [ -z "$result" ]
}

@test "imported_hashes: emits _source_hash for every rule that has one" {
  cat > "$USER_ROOT/.claude/passthru.imported.json" <<'JSON'
{
  "version": 1,
  "allow": [
    {"tool":"Bash","match":{"command":"^x$"},"_source_hash":"aaa111"},
    {"tool":"Bash","match":{"command":"^y$"},"_source_hash":"bbb222"}
  ],
  "deny": []
}
JSON
  result="$(imported_hashes | sort)"
  expected="$(printf '%s\n%s\n' 'aaa111' 'bbb222' | sort)"
  [ "$result" = "$expected" ]
}

@test "imported_hashes: rules without _source_hash contribute nothing" {
  cat > "$USER_ROOT/.claude/passthru.imported.json" <<'JSON'
{
  "version": 1,
  "allow": [
    {"tool":"Bash","match":{"command":"^x$"},"_source_hash":"aaa"},
    {"tool":"Bash","match":{"command":"^legacy$"}}
  ],
  "deny": []
}
JSON
  result="$(imported_hashes)"
  [ "$result" = "aaa" ]
}

@test "imported_hashes: user and project scope both contribute" {
  cat > "$USER_ROOT/.claude/passthru.imported.json" <<'JSON'
{"version":1,"allow":[{"tool":"Bash","_source_hash":"u1"}],"deny":[]}
JSON
  cat > "$PROJ_ROOT/.claude/passthru.imported.json" <<'JSON'
{"version":1,"allow":[{"tool":"Bash","_source_hash":"p1"}],"deny":[]}
JSON
  result="$(imported_hashes | sort)"
  expected="$(printf '%s\n%s\n' 'p1' 'u1')"
  [ "$result" = "$expected" ]
}

@test "imported_hashes: malformed file is silently skipped" {
  printf 'not-json{' > "$USER_ROOT/.claude/passthru.imported.json"
  result="$(imported_hashes)"
  [ -z "$result" ]
}
