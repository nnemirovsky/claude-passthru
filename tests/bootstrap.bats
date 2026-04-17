#!/usr/bin/env bats

# tests/bootstrap.bats
# Covers scripts/bootstrap.sh: conversion of native permission rules into
# passthru format, dry-run output, --write mode, backup/rollback on verifier
# failure, and regex regression for the evilx.com / x.com boundary.
# Hermetic via synthetic PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR roots.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
  VERIFY="$REPO_ROOT/scripts/verify.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures"

  TMP="$(mktemp -d -t passthru-bootstrap-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"

  # Pull in passthru_sha256 so the before/after equality checks use SHA-256
  # consistently (the older inline fallback mixed shasum defaults, which
  # degrade to SHA-1 when -a is omitted).
  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

user_imported() { printf '%s/.claude/passthru.imported.json\n' "$USER_ROOT"; }
proj_imported() { printf '%s/.claude/passthru.imported.json\n' "$PROJ_ROOT"; }
user_authored() { printf '%s/.claude/passthru.json\n' "$USER_ROOT"; }
proj_authored() { printf '%s/.claude/passthru.json\n' "$PROJ_ROOT"; }

run_boot() {
  run bash "$BOOTSTRAP" "$@"
}

# ---------------------------------------------------------------------------
# Usage / argument parsing
# ---------------------------------------------------------------------------

@test "bootstrap: --help exits 0 with usage text" {
  run_boot --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "bootstrap: unknown flag -> non-zero exit" {
  run_boot --nope
  [ "$status" -ne 0 ]
}

@test "bootstrap: --user-only + --project-only are mutually exclusive" {
  run_boot --user-only --project-only
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Empty scopes
# ---------------------------------------------------------------------------

@test "bootstrap: no settings files at all -> exits 0, writes nothing in dry-run" {
  run_boot
  [ "$status" -eq 0 ]
  # Dry-run prints two documents with empty allow arrays.
  [ ! -f "$(user_imported)" ]
  [ ! -f "$(proj_imported)" ]
}

@test "bootstrap: empty permissions.allow -> dry-run shows empty allow arrays" {
  printf '{"permissions":{"allow":[]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot
  [ "$status" -eq 0 ]
  # Expect an empty allow in output for user scope.
  [[ "$output" == *'"allow": []'* ]]
}

@test "bootstrap: empty allow + --write -> creates empty doc, verifier passes" {
  printf '{"permissions":{"allow":[]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --write
  [ "$status" -eq 0 ]
  [ -f "$(user_imported)" ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
  run jq -r '.version' "$(user_imported)"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# Mix-fixture conversions
# ---------------------------------------------------------------------------

@test "bootstrap: mix fixture converts Bash prefix, exact, MCP, WebFetch" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run_boot
  [ "$status" -eq 0 ]
  # Bash prefix
  [[ "$output" == *'"command": "^git\\ status(\\s|$)"'* ]]
  # Bash exact
  [[ "$output" == *'"command": "^echo\\ hello$"'* ]]
  # MCP exact
  [[ "$output" == *'"tool": "^mcp__context7__query\\-docs$"'* ]]
  # WebFetch stricter domain regex
  [[ "$output" == *'"url": "^https?://([^/.]+\\.)*x\\.com([/:?#]|$)"'* ]]
  # Unknown formats warning on stderr (run merges stderr in bats by default when run with 2>&1).
}

@test "bootstrap: unknown forms emit [WARN] to stderr and are skipped" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run bash -c "bash '$BOOTSTRAP' 2>&1 >/dev/null"
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"ExactStrangeFormat"* ]]
}

@test "bootstrap: --write persists converted rules to project .imported.json" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  [ -f "$(proj_imported)" ]
  run jq -r '.allow | length' "$(proj_imported)"
  # fixture has 19 entries, 1 skipped (ExactStrangeFormat) -> 18 kept
  [ "$output" = "18" ]
}

@test "bootstrap: dry-run output matches --write file content (schema-wise)" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  # Use --project-only so dry-run stdout contains a single document.
  # Strip the "# would write: ..." marker line(s) and parse the rest as JSON.
  # This is independent of the marker text exact form.
  dry="$(bash "$BOOTSTRAP" --project-only 2>/dev/null | grep -v '^#')"
  # Validate the dry output is a JSON document.
  printf '%s' "$dry" | jq -e '.' >/dev/null
  run bash "$BOOTSTRAP" --project-only --write
  [ "$status" -eq 0 ]
  # Compare semantic JSON equality.
  run jq --argjson a "$(cat "$(proj_imported)")" --argjson b "$dry" -n '$a == $b'
  [ "$output" = "true" ]
}

# ---------------------------------------------------------------------------
# Scope flags
# ---------------------------------------------------------------------------

@test "bootstrap: --user-only skips project scope entirely" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  [ -f "$(user_imported)" ]
  [ ! -f "$(proj_imported)" ]
  run jq -r '.allow[0].match.command' "$(user_imported)"
  [ "$output" = "^ls(\\s|\$)" ]
}

@test "bootstrap: --project-only skips user scope entirely" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --project-only --write
  [ "$status" -eq 0 ]
  [ ! -f "$(user_imported)" ]
  [ -f "$(proj_imported)" ]
}

# ---------------------------------------------------------------------------
# Malformed settings files
# ---------------------------------------------------------------------------

@test "bootstrap: malformed settings.json -> error mentions file path, exit non-zero" {
  printf 'not-json{' > "$PROJ_ROOT/.claude/settings.local.json"
  run bash -c "bash '$BOOTSTRAP' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PROJ_ROOT/.claude/settings.local.json"* ]]
}

# ---------------------------------------------------------------------------
# Re-run cleanliness + authored file untouched
# ---------------------------------------------------------------------------

@test "bootstrap: re-run replaces imported cleanly; authored passthru.json untouched" {
  # Place an authored passthru.json with hand-written content.
  cat > "$(proj_authored)" <<'JSON'
{
  "version": 1,
  "allow": [
    {
      "tool": "Bash",
      "match": { "command": "^make\\b" },
      "reason": "hand-authored"
    }
  ],
  "deny": []
}
JSON
  # Stable checksum to compare before/after
  before_sum="$(passthru_sha256 "$(proj_authored)")"
  # First bootstrap run
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]

  # Capture imported content after first run
  first_sum="$(passthru_sha256 "$(proj_imported)")"

  # Change the settings file and re-run -> imported content changes, authored is still untouched
  printf '{"permissions":{"allow":["Bash(pwd:*)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(proj_imported)"
  [ "$output" = "1" ]
  run jq -r '.allow[0].match.command' "$(proj_imported)"
  [ "$output" = "^pwd(\\s|\$)" ]

  # Authored file byte-identical
  after_sum="$(passthru_sha256 "$(proj_authored)")"
  [ "$before_sum" = "$after_sum" ]
}

# ---------------------------------------------------------------------------
# Regex regression: evilx.com must NOT match x.com rule
# ---------------------------------------------------------------------------

@test "bootstrap: x.com import does NOT match evilx.com (regex probe via perl)" {
  printf '{"permissions":{"allow":["WebFetch(domain:x.com)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  # Pull the generated url pattern.
  pat="$(jq -r '.allow[0].match.url' "$(proj_imported)")"
  # Must match x.com and sub.x.com
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.com/' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://sub.x.com/a' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match evilx.com
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://evilx.com/anything' "$pat"
  [ "$status" -ne 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://sub.evilx.com/' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: WebFetch(domain:x.com) matches same-host URL with query/fragment/port (regex trailing anchors)" {
  # The native `WebFetch(domain:x.com)` rule covers the host regardless of
  # what follows in the URL. The converted regex's trailing anchor must
  # therefore accept every legal URL delimiter that can follow the host:
  # `/` (path), `?` (query), `#` (fragment), `:` (port), or end-of-string.
  # An older `(/|$)` anchor rejected `https://x.com?foo=1` and `#frag`,
  # making the migration lossy vs the native rule.
  printf '{"permissions":{"allow":["WebFetch(domain:x.com)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.url' "$(proj_imported)")"
  # Plain host
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.com' "$pat"
  [ "$status" -eq 0 ]
  # Host with query
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.com?foo=1' "$pat"
  [ "$status" -eq 0 ]
  # Host with fragment
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.com#frag' "$pat"
  [ "$status" -eq 0 ]
  # Host with explicit port
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.com:8443/api' "$pat"
  [ "$status" -eq 0 ]
  # Host with trailing path and query together
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.com/a?b=1#c' "$pat"
  [ "$status" -eq 0 ]
  # Must STILL NOT match `evilx.com` variants (regression guard for the
  # `([^/.]+\\.)*` boundary check).
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://evilx.com?foo=1' "$pat"
  [ "$status" -ne 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://evilx.com#frag' "$pat"
  [ "$status" -ne 0 ]
  # And must still not match a host that merely starts with `x.com` followed
  # by more label chars (e.g. `x.com.attacker.net` under the naive anchor).
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'https://x.comattacker.net/' "$pat"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# End-to-end roundtrip: bootstrap --write then verifier passes
# ---------------------------------------------------------------------------

@test "bootstrap: roundtrip -> bootstrap --write then verify.sh exits 0" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  run bash "$VERIFY" --quiet
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Verifier failure rollback: simulate via an existing authored file that,
# merged with the imported, triggers a conflict (same rule in allow + deny).
# ---------------------------------------------------------------------------

@test "bootstrap: verifier failure during --write -> rollback, imported file unchanged" {
  # Place an authored passthru.json with a DENY rule that exactly matches what
  # bootstrap would import as ALLOW (triggers the verifier's conflict check).
  cat > "$(proj_authored)" <<'JSON'
{
  "version": 1,
  "allow": [],
  "deny": [
    {
      "tool": "Bash",
      "match": { "command": "^ls(\\s|$)" },
      "reason": "local deny"
    }
  ]
}
JSON
  # Seed an existing imported file with a known payload.
  cat > "$(proj_imported)" <<'JSON'
{
  "version": 1,
  "allow": [
    {
      "tool": "Bash",
      "match": { "command": "^pre-existing(\\s|$)" },
      "reason": "pre-existing imported"
    }
  ],
  "deny": []
}
JSON
  # Capture pre-bootstrap checksum of imported.
  before_sum="$(passthru_sha256 "$(proj_imported)")"

  # Settings that would import ls as Bash allow -> conflict with the deny.
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run bash -c "bash '$BOOTSTRAP' --write 2>&1"
  [ "$status" -ne 0 ]

  # Imported file should be unchanged (rolled back from backup).
  after_sum="$(passthru_sha256 "$(proj_imported)")"
  [ "$before_sum" = "$after_sum" ]
}

# ---------------------------------------------------------------------------
# Regex escaping edge cases in Bash prefix
# ---------------------------------------------------------------------------

@test "bootstrap: prefix with dots + slashes is escaped as literal" {
  printf '{"permissions":{"allow":["Bash(/opt/homebrew/bin/ggrep --version:*)"]}}\n' \
    > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.command' "$(proj_imported)")"
  # Must match the literal string only
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' \
    '/opt/homebrew/bin/ggrep --version something' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match something crafted to exploit unescaped dots
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' \
    '/optxhomebrewxbinxggrep --version' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: prefix with regex metacharacters is escaped" {
  printf '{"permissions":{"allow":["Bash(echo $HOME:*)"]}}\n' \
    > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.command' "$(proj_imported)")"
  # $ is a regex anchor - must be escaped so the rule matches literal `echo $HOME`.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'echo $HOME foo' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match `echo X` (without the literal `$HOME`).
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'echo X foo' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: prefix with asterisk and brackets is escaped" {
  printf '{"permissions":{"allow":["Bash(grep -P [abc].*:*)"]}}\n' \
    > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.command' "$(proj_imported)")"
  # Must match the literal prefix
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'grep -P [abc].* file' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT treat [abc] as a character class
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'grep -P aZZZ' "$pat"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Both user and project scopes
# ---------------------------------------------------------------------------

@test "bootstrap: both scopes populated -> separate imported files" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"permissions":{"allow":["Bash(pwd:*)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  [ -f "$(user_imported)" ]
  [ -f "$(proj_imported)" ]
  run jq -r '.allow[0].match.command' "$(user_imported)"
  [ "$output" = "^ls(\\s|\$)" ]
  run jq -r '.allow[0].match.command' "$(proj_imported)"
  [ "$output" = "^pwd(\\s|\$)" ]
}

@test "bootstrap: project scope merges shared + local settings, dedups" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$PROJ_ROOT/.claude/settings.json"
  printf '{"permissions":{"allow":["Bash(ls:*)","Bash(pwd:*)"]}}\n' \
    > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(proj_imported)"
  # Two unique rules (ls appears twice -> deduped).
  [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# Edge cases: read-only target dirs, deny-only settings, non-string entries
# ---------------------------------------------------------------------------

@test "bootstrap: --write into read-only target dir -> non-zero exit, stderr error" {
  # Make the user .claude dir read-only after seeding the source settings.
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: chmod 555 does not deny writes to uid 0"
  fi
  chmod 555 "$USER_ROOT/.claude" 2>/dev/null || skip "cannot chmod test dir"
  run bash -c "bash '$BOOTSTRAP' --user-only --write 2>&1"
  # Restore so teardown can rm -rf.
  chmod 755 "$USER_ROOT/.claude" 2>/dev/null || true
  # We expect a failure: either mv-into-place fails or verify cannot read
  # the new file. Either way, exit must not be 0 and the imported file must
  # not have been written successfully.
  [ "$status" -ne 0 ]
  [ ! -f "$(user_imported)" ] || skip "platform allowed write through read-only dir"
}

@test "bootstrap: settings has only permissions.deny (no allow) -> empty imported" {
  # We import only allow entries; deny entries are out of scope. A settings
  # file with deny[] but no allow[] must still bootstrap cleanly to an empty
  # rule set rather than skipping the file or erroring out.
  printf '{"permissions":{"deny":["Bash(rm:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  [ -f "$(user_imported)" ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: permissions.allow with non-string entries -> non-strings dropped, strings kept" {
  # convert_settings_file uses `map(select(type == "string"))`. Mix in a
  # number, a boolean, an object, and a null; only the string entries
  # should land in the output.
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{"permissions":{"allow":[123, true, null, {"k":"v"}, "Bash(ls:*)"]}}
EOF
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  [ -f "$(user_imported)" ]
  # Exactly one rule survived (Bash(ls:*)).
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "1" ]
  run jq -r '.allow[0].match.command' "$(user_imported)"
  [ "$output" = "^ls(\\s|\$)" ]
}

# ---------------------------------------------------------------------------
# WebSearch converter
# ---------------------------------------------------------------------------

@test "bootstrap: WebSearch converts to ^WebSearch$ tool rule with no match block" {
  printf '{"permissions":{"allow":["WebSearch"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "1" ]
  run jq -r '.allow[0].tool' "$(user_imported)"
  [ "$output" = "^WebSearch\$" ]
  # No match block should be present.
  run jq -r '.allow[0] | has("match")' "$(user_imported)"
  [ "$output" = "false" ]
}

# ---------------------------------------------------------------------------
# Read/Edit/Write file_path converters
# ---------------------------------------------------------------------------

@test "bootstrap: Read(/tmp/foo/**) converts to Read tool with prefix regex" {
  printf '{"permissions":{"allow":["Read(/tmp/foo/**)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow[0].tool' "$(user_imported)"
  [ "$output" = "^Read\$" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # Must match /tmp/foo and everything under it.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/tmp/foo' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/tmp/foo/bar' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/tmp/foo/bar/baz' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match /tmp/foobar (sibling with same prefix).
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/tmp/foobar' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: Read(/etc/hosts) converts to exact file_path match" {
  printf '{"permissions":{"allow":["Read(/etc/hosts)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow[0].tool' "$(user_imported)"
  [ "$output" = "^Read\$" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # Must match exactly.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/etc/hosts' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match /etc/hosts.bak or subpaths.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/etc/hosts.bak' "$pat"
  [ "$status" -ne 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/etc/hosts/sub' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: Edit(/path) converts with same file_path shape as Read" {
  printf '{"permissions":{"allow":["Edit(/var/log/app.log)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow[0].tool' "$(user_imported)"
  [ "$output" = "^Edit\$" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/var/log/app.log' "$pat"
  [ "$status" -eq 0 ]
}

@test "bootstrap: Write(/path/**) converts to Write prefix regex" {
  printf '{"permissions":{"allow":["Write(/tmp/out/**)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow[0].tool' "$(user_imported)"
  [ "$output" = "^Write\$" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/tmp/out/file.txt' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/tmp/output' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: Read path with regex metachars (dots, asterisks) is escaped" {
  # A literal path with regex metacharacters (dot, asterisk) must be escaped
  # so the resulting pattern matches only the literal path and does not
  # admit anything a greedy reader would allow.
  printf '{"permissions":{"allow":["Read(/a.b/c*/**)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # Must match the literal path.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/a.b/c*' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/a.b/c*/file' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match paths that only pass because dots and asterisks were
  # treated as regex operators.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/aXb/cZZ' "$pat"
  [ "$status" -ne 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/a/b/c/file' "$pat"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Skill converter
# ---------------------------------------------------------------------------

@test "bootstrap: Skill(revdiff) converts to ^Skill$ with {skill: ^revdiff$}" {
  printf '{"permissions":{"allow":["Skill(revdiff)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow[0].tool' "$(user_imported)"
  [ "$output" = "^Skill\$" ]
  run jq -r '.allow[0].match.skill' "$(user_imported)"
  [ "$output" = "^revdiff\$" ]
}

@test "bootstrap: Skill name with metachars is escaped" {
  printf '{"permissions":{"allow":["Skill(my.skill*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.skill' "$(user_imported)")"
  # Must match literal name only.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'my.skill*' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match a name that only passes because . or * were unescaped.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' 'myXskill' "$pat"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Regressions: Bash, MCP, WebFetch still convert with the new converters added.
# ---------------------------------------------------------------------------

@test "bootstrap: Bash/MCP/WebFetch conversions still work alongside new converters" {
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{"permissions":{"allow":[
  "Bash(git status:*)",
  "Bash(echo hello)",
  "mcp__context7__query-docs",
  "WebFetch(domain:docs.anthropic.com)",
  "WebSearch",
  "Read(/tmp/foo/**)",
  "Skill(revdiff)"
]}}
EOF
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "7" ]
  # Spot-check each shape.
  run jq -r '[.allow[].tool] | sort | join(",")' "$(user_imported)"
  [[ "$output" == *'Bash'* ]]
  [[ "$output" == *'WebFetch'* ]]
  [[ "$output" == *'^WebSearch$'* ]]
  [[ "$output" == *'^Read$'* ]]
  [[ "$output" == *'^Skill$'* ]]
  [[ "$output" == *'^mcp__context7__query\-docs$'* ]]
}

# ---------------------------------------------------------------------------
# Read/Edit/Write path normalization: leading `//` collapses to a single `/`,
# matching Node's `path.resolve()` behaviour in Claude Code. Previously the
# converter treated `Read(//...)` as "unusual" and skipped it. The hook
# payload always carries a resolved, single-slash path, so a rule generated
# from a `//...` entry would never match unless we normalize at import time.
# ---------------------------------------------------------------------------

@test "bootstrap: Read(//private/tmp/foo/**) normalizes to single leading slash" {
  printf '{"permissions":{"allow":["Read(//private/tmp/foo/**)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "1" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # The resulting regex must NOT carry two leading slashes (`regex_escape`
  # would emit `\/\/` for the unnormalized form).
  [[ "$pat" != *'\/\/'* ]]
  # Must match the single-slash form Claude Code passes to the hook after
  # Node's `path.resolve()` normalization, and everything under it.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/private/tmp/foo' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/private/tmp/foo/bar' "$pat"
  [ "$status" -eq 0 ]
  # Must NOT match a sibling that only shares the prefix literally.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/private/tmp/foobar' "$pat"
  [ "$status" -ne 0 ]
}

@test "bootstrap: Read(///deeply/nested/**) collapses all redundant slashes" {
  printf '{"permissions":{"allow":["Read(///deeply/nested/**)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # No repeated escaped slashes should remain - normalization happens before
  # the path gets escaped.
  [[ "$pat" != *'\/\/'* ]]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/deeply/nested/x' "$pat"
  [ "$status" -eq 0 ]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/deeply/nested' "$pat"
  [ "$status" -eq 0 ]
}

@test "bootstrap: Read path with embedded double slash is normalized" {
  printf '{"permissions":{"allow":["Read(/a//b/c)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # Embedded `//` collapses to single `/` before regex escaping.
  [[ "$pat" != *'\/\/'* ]]
  # The resulting (exact-form) regex matches the single-slash literal path.
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/a/b/c' "$pat"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Read/Edit/Write skip cases for clearly invalid path shapes.
# ---------------------------------------------------------------------------

@test "bootstrap: Read(~user/.ssh) skipped (tilde variant not supported)" {
  printf '{"permissions":{"allow":["Read(~user/.ssh)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"tilde variant not supported"* ]]
  [[ "$output" == *"~user/.ssh"* ]]
  # --write should produce an empty allow list (rule was skipped).
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: Read(~+) and Read(~-) skipped (tilde variants)" {
  printf '{"permissions":{"allow":["Read(~+)","Read(~-)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"tilde variant not supported"* ]]
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: Read(~/foo) expands to \$HOME/foo (bare ~/ is accepted)" {
  printf '{"permissions":{"allow":["Read(~/foo/**)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "1" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  # The resolved path should start with the current HOME and end with the
  # prefix-form suffix.
  [[ "$pat" == "^"*"/foo(/|\$)" ]]
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' "$HOME/foo" "$pat"
  [ "$status" -eq 0 ]
}

@test "bootstrap: Read(\$HOME/x) skipped (shell expansion syntax)" {
  printf '{"permissions":{"allow":["Read($HOME/x)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"shell expansion syntax not supported"* ]]
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: Read(\${HOME}/x) and Read(\$(pwd)/x) skipped (shell expansion)" {
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{"permissions":{"allow":["Read(${HOME}/x)","Read($(pwd)/x)"]}}
EOF
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"shell expansion syntax not supported"* ]]
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: Read(%APPDATA%) skipped (windows env expansion)" {
  printf '{"permissions":{"allow":["Read(%%APPDATA%%/foo)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"shell expansion syntax not supported"* ]]
}

@test "bootstrap: Read(=cmd) skipped (zsh equals expansion)" {
  printf '{"permissions":{"allow":["Read(=cmd)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"shell expansion syntax not supported"* ]]
}

@test "bootstrap: Read(\\\\server\\share) skipped (UNC path)" {
  # Feed a literal two-backslash `\\server\share` via a file (bash printf is
  # too fiddly for doubled backslashes in JSON).
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{"permissions":{"allow":["Read(\\\\server\\share)"]}}
EOF
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"UNC path not supported"* ]]
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: Edit and Write honor the same skip rules as Read" {
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{"permissions":{"allow":["Edit($HOME/x)","Write(=foo)"]}}
EOF
  run bash -c "bash '$BOOTSTRAP' --user-only 2>&1 >/dev/null"
  [[ "$output" == *"Edit("* ]]
  [[ "$output" == *"Write("* ]]
  [[ "$output" == *"shell expansion syntax not supported"* ]]
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "0" ]
}

@test "bootstrap: Read(/path/with spaces/**) accepted (spaces are not a reject reason)" {
  # Claude Code accepts paths with spaces; only shell-expansion, tilde
  # variants, and UNC are rejected. Verify the converter keeps this entry.
  printf '{"permissions":{"allow":["Read(/path/with spaces/**)"]}}\n' \
    > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_imported)"
  [ "$output" = "1" ]
  pat="$(jq -r '.allow[0].match.file_path' "$(user_imported)")"
  run perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/' '/path/with spaces/file' "$pat"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _source_hash embedded on every imported rule (enables session-start diff)
# ---------------------------------------------------------------------------

@test "bootstrap: every imported rule has _source_hash matching hash_settings_entry" {
  printf '%s\n' \
    '{"permissions":{"allow":["Bash(ls:*)","WebSearch","mcp__x__y","WebFetch(domain:x.com)","Read(/tmp/**)","Skill(revdiff)","Bash(echo hi)"]}}' \
    > "$USER_ROOT/.claude/settings.json"
  run_boot --user-only --write
  [ "$status" -eq 0 ]

  # Every allow rule must carry a 64-char hex _source_hash.
  bad="$(jq -r '[.allow[] | select((._source_hash == null) or ((._source_hash | test("^[0-9a-f]{64}$")) | not))] | length' "$(user_imported)")"
  [ "$bad" = "0" ]

  # The hash of each entry must match hash_settings_entry.
  for entry in 'Bash(ls:*)' 'WebSearch' 'mcp__x__y' 'WebFetch(domain:x.com)' 'Read(/tmp/**)' 'Skill(revdiff)' 'Bash(echo hi)'; do
    expected="$(hash_settings_entry "$entry")"
    found="$(jq -r --arg h "$expected" '[.allow[] | select(._source_hash == $h)] | length' "$(user_imported)")"
    [ "$found" = "1" ] || {
      echo "hash for '$entry' ($expected) not found in imported allow[]" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# additionalAllowedWorkingDirs import
# ---------------------------------------------------------------------------

@test "bootstrap: imports additionalAllowedWorkingDirs from user settings" {
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(ls:*)"]},
  "env": {"additionalAllowedWorkingDirs": ["/opt/shared", "/data/reference"]}
}
EOF
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  [ -f "$(user_imported)" ]
  # Check that allowed_dirs are present in the imported file.
  run jq -r '.allowed_dirs | length' "$(user_imported)"
  [ "$output" = "2" ]
  run jq -r '.allowed_dirs[0]' "$(user_imported)"
  [ "$output" = "/opt/shared" ]
  run jq -r '.allowed_dirs[1]' "$(user_imported)"
  [ "$output" = "/data/reference" ]
}

@test "bootstrap: no additionalAllowedWorkingDirs -> no allowed_dirs key in output" {
  cat > "$USER_ROOT/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(ls:*)"]}}
EOF
  run_boot --user-only --write
  [ "$status" -eq 0 ]
  # allowed_dirs should NOT be present.
  run jq 'has("allowed_dirs")' "$(user_imported)"
  [ "$output" = "false" ]
}

@test "bootstrap: project scope merges allowed dirs from shared + local settings" {
  cat > "$PROJ_ROOT/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": []},
  "env": {"additionalAllowedWorkingDirs": ["/opt/shared"]}
}
EOF
  cat > "$PROJ_ROOT/.claude/settings.local.json" <<'EOF'
{
  "permissions": {"allow": []},
  "env": {"additionalAllowedWorkingDirs": ["/opt/shared", "/data/local"]}
}
EOF
  run_boot --project-only --write
  [ "$status" -eq 0 ]
  # Deduplicated: /opt/shared appears once, /data/local once.
  run jq -r '.allowed_dirs | length' "$(proj_imported)"
  [ "$output" = "2" ]
  # Both dirs present (order from jq unique is sorted).
  run jq -r '.allowed_dirs | sort | join(",")' "$(proj_imported)"
  [ "$output" = "/data/local,/opt/shared" ]
}

@test "bootstrap: re-running --write is idempotent at the hash level" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(echo hello)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_boot --user-only --write
  [ "$status" -eq 0 ]
  first="$(jq -S '[.allow[]._source_hash] | sort' "$(user_imported)")"

  run_boot --user-only --write
  [ "$status" -eq 0 ]
  second="$(jq -S '[.allow[]._source_hash] | sort' "$(user_imported)")"

  [ "$first" = "$second" ]
}

@test "bootstrap: hash is case-sensitive (Bash and bash produce distinct hashes)" {
  # A Bash entry and an unrecognised-but-importable test: only the valid one
  # produces output, but this test targets hash stability itself via the
  # helper, not the converter.
  a="$(hash_settings_entry 'Bash(ls:*)')"
  b="$(hash_settings_entry 'bash(ls:*)')"
  [ "$a" != "$b" ]
}

@test "bootstrap: rule identity dedup still works with _source_hash present" {
  # The identity canon uses {tool, match} only; two identical entries across
  # user scope (shared + local) must collapse to one imported rule even
  # though each pass attaches a hash.
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$PROJ_ROOT/.claude/settings.local.json"

  run_boot --project-only --write
  [ "$status" -eq 0 ]
  count="$(jq -r '.allow | length' "$(proj_imported)")"
  [ "$count" = "1" ]
  # And the single rule does carry a _source_hash.
  hash_val="$(jq -r '.allow[0]._source_hash' "$(proj_imported)")"
  expected="$(hash_settings_entry 'Bash(ls:*)')"
  [ "$hash_val" = "$expected" ]
}
