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
  [[ "$output" == *'"url": "^https?://([^/.]+\\.)*x\\.com(/|$)"'* ]]
  # Unknown formats warning on stderr (run merges stderr in bats by default when run with 2>&1).
}

@test "bootstrap: unknown forms emit [WARN] to stderr and are skipped" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run bash -c "bash '$BOOTSTRAP' 2>&1 >/dev/null"
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"Read(/tmp/foo)"* ]] || [[ "$output" == *"ExactStrangeFormat"* ]]
}

@test "bootstrap: --write persists converted rules to project .imported.json" {
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  [ -f "$(proj_imported)" ]
  run jq -r '.allow | length' "$(proj_imported)"
  # fixture has 13 entries, 2 skipped (Read, ExactStrangeFormat) -> 11 kept
  [ "$output" = "11" ]
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
  if command -v shasum >/dev/null 2>&1; then
    before_sum="$(shasum "$(proj_authored)" | awk '{print $1}')"
  else
    before_sum="$(sha1sum "$(proj_authored)" | awk '{print $1}')"
  fi
  # First bootstrap run
  cp "$FIXTURES/settings-with-allow.json" "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]

  # Capture imported content after first run
  first_sum=""
  if command -v shasum >/dev/null 2>&1; then
    first_sum="$(shasum "$(proj_imported)" | awk '{print $1}')"
  else
    first_sum="$(sha1sum "$(proj_imported)" | awk '{print $1}')"
  fi

  # Change the settings file and re-run -> imported content changes, authored is still untouched
  printf '{"permissions":{"allow":["Bash(pwd:*)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run_boot --write
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(proj_imported)"
  [ "$output" = "1" ]
  run jq -r '.allow[0].match.command' "$(proj_imported)"
  [ "$output" = "^pwd(\\s|\$)" ]

  # Authored file byte-identical
  if command -v shasum >/dev/null 2>&1; then
    after_sum="$(shasum "$(proj_authored)" | awk '{print $1}')"
  else
    after_sum="$(sha1sum "$(proj_authored)" | awk '{print $1}')"
  fi
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
  if command -v shasum >/dev/null 2>&1; then
    before_sum="$(shasum "$(proj_imported)" | awk '{print $1}')"
  else
    before_sum="$(sha1sum "$(proj_imported)" | awk '{print $1}')"
  fi

  # Settings that would import ls as Bash allow -> conflict with the deny.
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$PROJ_ROOT/.claude/settings.local.json"
  run bash -c "bash '$BOOTSTRAP' --write 2>&1"
  [ "$status" -ne 0 ]

  # Imported file should be unchanged (rolled back from backup).
  if command -v shasum >/dev/null 2>&1; then
    after_sum="$(shasum "$(proj_imported)" | awk '{print $1}')"
  else
    after_sum="$(sha1sum "$(proj_imported)" | awk '{print $1}')"
  fi
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
