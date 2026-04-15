#!/usr/bin/env bats

# tests/write_rule.bats
# Covers scripts/write-rule.sh atomic behaviour: happy path append, backup
# rollback on verifier failure, missing-target bootstrapping, and concurrent
# write serialization. Synthetic PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR
# keep the tests hermetic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WRITE="$REPO_ROOT/scripts/write-rule.sh"

  TMP="$(mktemp -d -t passthru-write-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

user_file() {
  printf '%s/.claude/passthru.json\n' "$USER_ROOT"
}

proj_file() {
  printf '%s/.claude/passthru.json\n' "$PROJ_ROOT"
}

run_write() {
  run bash "$WRITE" "$@"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "write-rule: missing args -> exit 1 with usage" {
  run_write
  [ "$status" -eq 1 ]
}

@test "write-rule: invalid scope -> exit 1" {
  run_write global allow '{"tool":"Bash"}'
  [ "$status" -eq 1 ]
}

@test "write-rule: invalid list -> exit 1" {
  run_write user block '{"tool":"Bash"}'
  [ "$status" -eq 1 ]
}

@test "write-rule: non-object rule_json -> exit 1" {
  run_write user allow '[1,2,3]'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "write-rule: happy path appends a valid rule (user scope)" {
  run_write user allow '{"tool":"Bash","match":{"command":"^ls"},"reason":"list"}'
  [ "$status" -eq 0 ]
  [ -f "$(user_file)" ]
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.allow[0].tool' "$(user_file)"
  [ "$output" = "Bash" ]
  run jq -r '.allow[0].match.command' "$(user_file)"
  [ "$output" = "^ls" ]
}

@test "write-rule: happy path appends a deny rule" {
  run_write user deny '{"tool":"Bash","match":{"command":"rm\\s+-rf\\s+/"}}'
  [ "$status" -eq 0 ]
  run jq -r '.deny[0].tool' "$(user_file)"
  [ "$output" = "Bash" ]
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "0" ]
}

@test "write-rule: project scope targets the right file" {
  run_write project allow '{"tool":"Read","match":{"file_path":"^/tmp/"}}'
  [ "$status" -eq 0 ]
  [ -f "$(proj_file)" ]
  # User file must not be created or modified.
  [ ! -f "$(user_file)" ]
}

@test "write-rule: multiple appends accumulate" {
  run_write user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -eq 0 ]
  run_write user allow '{"tool":"Bash","match":{"command":"^pwd"}}'
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.allow[0].match.command' "$(user_file)"
  [ "$output" = "^ls" ]
  run jq -r '.allow[1].match.command' "$(user_file)"
  [ "$output" = "^pwd" ]
}

# ---------------------------------------------------------------------------
# Missing target creation
# ---------------------------------------------------------------------------

@test "write-rule: missing target file is created with correct skeleton" {
  # Confirm file does not exist before the write.
  [ ! -f "$(user_file)" ]
  run_write user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -eq 0 ]
  [ -f "$(user_file)" ]
  # Fresh-file skeleton must be v2 and include all three arrays so the
  # file self-documents ask support. allow now holds the new rule, ask
  # and deny are still empty.
  run jq -e '.version == 2
             and (.allow | type == "array")
             and (.ask   | type == "array")
             and (.deny  | type == "array")' "$(user_file)"
  [ "$status" -eq 0 ]
}

@test "write-rule: creates parent directory if missing" {
  # Remove the .claude dir to test mkdir -p path.
  rm -rf "$USER_ROOT/.claude"
  run_write user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -eq 0 ]
  [ -d "$USER_ROOT/.claude" ]
  [ -f "$(user_file)" ]
}

# ---------------------------------------------------------------------------
# Rollback on verifier failure
# ---------------------------------------------------------------------------

@test "write-rule: invalid regex -> backup restored, exit non-zero" {
  # Seed a valid baseline.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  ORIG="$(cat "$(user_file)")"

  # Run with stderr merged into stdout so we can assert on it directly.
  run bash -c "bash '$WRITE' user allow '{\"tool\":\"Bash\",\"match\":{\"command\":\"[\"}}' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verifier"* ]]
  # File must be byte-for-byte identical to the original.
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

@test "write-rule: invalid regex on new file -> file still exists in valid shape" {
  # No baseline -> write-rule creates the skeleton, then tries to append.
  [ ! -f "$(user_file)" ]
  run bash -c "bash '$WRITE' user allow '{\"tool\":\"Bash\",\"match\":{\"command\":\"[\"}}' 2>&1"
  [ "$status" -ne 0 ]
  # File must exist and be the valid v2 skeleton (all three arrays empty
  # after rollback).
  [ -f "$(user_file)" ]
  run jq -e '.version == 2
             and (.allow | length == 0)
             and (.ask   | length == 0)
             and (.deny  | length == 0)' "$(user_file)"
  [ "$status" -eq 0 ]
}

@test "write-rule: verifier error surfaces on stderr" {
  run bash -c "bash '$WRITE' user allow '{\"tool\":\"Bash\",\"match\":{\"command\":\"[\"}}' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"regex"* ]] || [[ "$output" == *"rolled back"* ]]
}

@test "write-rule: conflict with existing rule -> rolled back" {
  # Seed a deny rule.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[{"tool":"Bash","match":{"command":"^ls"}}]}
EOF
  ORIG="$(cat "$(user_file)")"
  # Try to add the identical rule to allow -> triggers conflict.
  run_write user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -ne 0 ]
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

# ---------------------------------------------------------------------------
# Concurrent write serialization
# ---------------------------------------------------------------------------

@test "write-rule: concurrent writes serialize to exactly two rules" {
  # Spawn two writes in parallel to the same file with distinct rules. With
  # the mkdir-based lock both writers must serialize and BOTH must succeed
  # (the lock timeout is 5s by default, well above the time the verifier
  # takes). Final count must be exactly 2; "1 or 2" tolerated a real bug
  # where one writer silently failed.
  (
    bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^a1"}}' >/dev/null 2>&1
  ) &
  PID1=$!
  (
    bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^b2"}}' >/dev/null 2>&1
  ) &
  PID2=$!

  rc1=0
  rc2=0
  wait "$PID1" || rc1=$?
  wait "$PID2" || rc2=$?

  # Both writers must exit 0 (serialization, not failure).
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  # Final state must be valid JSON. Fresh-file skeleton is v2 so the
  # final document sits at version 2 with all three arrays present.
  [ -f "$(user_file)" ]
  run jq -e '.version == 2 and (.allow | type == "array")' "$(user_file)"
  [ "$status" -eq 0 ]

  # Exact count: 2.
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "2" ]
}

@test "write-rule: lock timeout respected when held externally" {
  # Simulate an externally-held lock by creating the mkdir-style lock dir.
  # write-rule.sh uses mkdir locking on every platform, so this is the
  # single, deterministic way to hold the lock from the test.
  LOCK_PATH="$USER_ROOT/.claude/passthru.write.lock"
  mkdir -p "$USER_ROOT/.claude"
  mkdir "${LOCK_PATH}.d"

  PASSTHRU_WRITE_LOCK_TIMEOUT=1 run bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -ne 0 ]

  rmdir "${LOCK_PATH}.d" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# File shape invariants
# ---------------------------------------------------------------------------

@test "write-rule: preserves existing rules across scopes" {
  # Seed a baseline user file.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[{"tool":"Bash","match":{"command":"^rm"}}]}
EOF
  run_write user allow '{"tool":"Bash","match":{"command":"^pwd"}}'
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "1" ]
  # Ordering preserved: existing rules come before the appended one.
  run jq -r '.allow[0].match.command' "$(user_file)"
  [ "$output" = "^ls" ]
  run jq -r '.allow[1].match.command' "$(user_file)"
  [ "$output" = "^pwd" ]
}

@test "write-rule: existing invalid target -> exit 1 before mutation" {
  # Write a broken JSON file.
  printf '{not valid json' > "$(user_file)"
  ORIG="$(cat "$(user_file)")"
  run_write user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -ne 0 ]
  # File must be untouched.
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

# ---------------------------------------------------------------------------
# Signal safety: signal arriving after mv-to-target but before verifier
# rollback must leave TARGET byte-identical to the pre-write content.
# ---------------------------------------------------------------------------

@test "write-rule: SIGTERM between mv-target and verifier -> TARGET rolled back, no corrupt content" {
  # Reproduce the exact atomic-write vulnerability window described in the
  # cleanup() STATE machine: after `mv TMPOUT TARGET` has replaced the
  # file, but BEFORE the verifier has returned and the `if VERIFY_RC -ne 0`
  # rollback branch has run. A signal caught in that window with a naive
  # EXIT-trap cleanup() would simply `rm BACKUP` and leave TARGET holding
  # unverified content with no restore path.
  #
  # To make the window deterministic, we work on an instrumented copy of
  # write-rule.sh that inserts a `sleep` between `mv` and the verifier
  # invocation. An external killer signals the write process during that
  # sleep. The underlying bug and fix are unchanged; the instrumentation
  # only widens a window that would otherwise race in microseconds.
  FAKE_ROOT="$TMP/fake-plugin-root"
  mkdir -p "$FAKE_ROOT/hooks" "$FAKE_ROOT/scripts"
  cp "$REPO_ROOT/hooks/common.sh" "$FAKE_ROOT/hooks/common.sh"
  # verify.sh under the fake root is a no-op success; the signal is
  # injected from the outside so we do not depend on verify's behavior.
  cat > "$FAKE_ROOT/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKE_ROOT/scripts/verify.sh"

  # Instrumented copy of write-rule.sh with a sleep inserted right after
  # `mv TMPOUT TARGET` to widen the post-mv / pre-verify window.
  INSTR_WRITE="$TMP/write-rule-instr.sh"
  awk '
    /^mv "\$TMPOUT" "\$TARGET"$/ { print; print "sleep 0.6"; next }
    { print }
  ' "$WRITE" > "$INSTR_WRITE"
  chmod +x "$INSTR_WRITE"
  # Sanity: make sure the sleep actually landed.
  grep -q '^sleep 0.6$' "$INSTR_WRITE"

  # Seed a valid baseline TARGET.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^original"}}],"deny":[]}
EOF
  ORIG="$(cat "$(user_file)")"

  # Launch write-rule.sh in the background, schedule a SIGTERM mid-sleep.
  CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    bash "$INSTR_WRITE" user allow '{"tool":"Bash","match":{"command":"^injected"}}' >/dev/null 2>&1 &
  wpid=$!
  (sleep 0.3; kill -TERM "$wpid" 2>/dev/null || true) &
  killer_pid=$!

  set +e
  wait "$wpid"
  wrc=$?
  set -e
  wait "$killer_pid" 2>/dev/null || true

  # Process must have exited non-zero (signal-driven exit).
  [ "$wrc" -ne 0 ]

  # Strongest assertion: file content restored byte-for-byte. Without the
  # STATE machine in cleanup(), BACKUP was rm'd and TARGET would still
  # hold the `^injected` rule here.
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

@test "write-rule: SIGTERM on a missing-target write -> skeleton preserved (no partial rule)" {
  # Same signal-injection technique, but on a first-write (no pre-existing
  # target). The skeleton `{"version":1,"allow":[],"deny":[]}` gets laid
  # down before the append, so the backup holds the skeleton and rollback
  # restores it rather than the injected rule.
  FAKE_ROOT="$TMP/fake-plugin-root-2"
  mkdir -p "$FAKE_ROOT/hooks" "$FAKE_ROOT/scripts"
  cp "$REPO_ROOT/hooks/common.sh" "$FAKE_ROOT/hooks/common.sh"
  cat > "$FAKE_ROOT/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKE_ROOT/scripts/verify.sh"

  INSTR_WRITE="$TMP/write-rule-instr-2.sh"
  awk '
    /^mv "\$TMPOUT" "\$TARGET"$/ { print; print "sleep 0.6"; next }
    { print }
  ' "$WRITE" > "$INSTR_WRITE"
  chmod +x "$INSTR_WRITE"

  [ ! -f "$(user_file)" ]

  CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    bash "$INSTR_WRITE" user allow '{"tool":"Bash","match":{"command":"^shouldnotland"}}' >/dev/null 2>&1 &
  wpid=$!
  (sleep 0.3; kill -TERM "$wpid" 2>/dev/null || true) &
  killer_pid=$!

  set +e
  wait "$wpid"
  wrc=$?
  set -e
  wait "$killer_pid" 2>/dev/null || true

  [ "$wrc" -ne 0 ]

  # The skeleton survives; the injected rule does not. Skeleton is created
  # before the backup/mv cycle starts, so BACKUP holds the skeleton and the
  # STATE-aware cleanup restores it. Fresh skeletons are v2.
  [ -f "$(user_file)" ]
  run jq -e '.version == 2
             and (.allow | length == 0)
             and (.ask   | length == 0)
             and (.deny  | length == 0)' "$(user_file)"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Same-filesystem atomic rename guarantee: BACKUP and TMPOUT must live in
# TARGET's directory so that `mv` is a rename(2) within one filesystem, not
# a copy+unlink across volumes. Without this, the atomic-write claim in the
# script header is false on any host where $HOME and the system temp dir
# live on different volumes (tmpfs on Linux, external $HOME on macOS).
# ---------------------------------------------------------------------------
@test "write-rule: BACKUP created in TARGET's directory, not system tmp" {
  # Strategy: instrument a copy of write-rule.sh to record where BACKUP and
  # TMPOUT get created, then inspect the recorded paths. This dodges timing
  # races entirely; the assertion is about the path variables, not a
  # filesystem scan during a brief window.
  FAKE_ROOT="$TMP/fake-plugin-root-loc"
  mkdir -p "$FAKE_ROOT/hooks" "$FAKE_ROOT/scripts"
  cp "$REPO_ROOT/hooks/common.sh" "$FAKE_ROOT/hooks/common.sh"
  cat > "$FAKE_ROOT/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKE_ROOT/scripts/verify.sh"

  RECORD="$TMP/tempfile-paths.log"
  INSTR_WRITE="$TMP/write-rule-instr-loc.sh"
  # After BACKUP/TMPOUT are assigned, log their values so the test can
  # inspect them independently of file lifetime.
  awk -v rec="$RECORD" '
    /^STATE="BACKED_UP"$/ { printf "printf '\''BACKUP=%%s\\n'\'' \"$BACKUP\" >> %s\n", rec; print; next }
    /^STATE="WRITING"$/   { printf "printf '\''TMPOUT=%%s\\n'\'' \"$TMPOUT\" >> %s\n", rec; print; next }
    { print }
  ' "$WRITE" > "$INSTR_WRITE"
  chmod +x "$INSTR_WRITE"

  # Seed a baseline so we exercise the "TARGET already exists" path.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[]}
EOF

  CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    bash "$INSTR_WRITE" user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$?" -eq 0 ]

  [ -f "$RECORD" ]
  TARGET_DIR="$(dirname "$(user_file)")"
  backup_path="$(grep '^BACKUP=' "$RECORD" | cut -d= -f2-)"
  tmpout_path="$(grep '^TMPOUT=' "$RECORD" | cut -d= -f2-)"

  [ -n "$backup_path" ]
  [ -n "$tmpout_path" ]

  # Both must live directly under TARGET's parent. That is the only property
  # the atomic-rename guarantee actually needs; it is also the property that
  # failed under `mktemp -t`, which places the file under whatever the system
  # temp dir is (potentially a different filesystem).
  backup_dir="$(dirname "$backup_path")"
  tmpout_dir="$(dirname "$tmpout_path")"
  [ "$backup_dir" = "$TARGET_DIR" ]
  [ "$tmpout_dir" = "$TARGET_DIR" ]

  # Filename shape should match the new mktemp templates so future reviewers
  # can see at a glance these are claude-passthru temp files.
  case "$(basename "$backup_path")" in
    passthru.json.backup.*) ;;
    *) false ;;
  esac
  case "$(basename "$tmpout_path")" in
    passthru.json.tmp.*) ;;
    *) false ;;
  esac
}

# ---------------------------------------------------------------------------
# Schema v2 + ask[] support (Task 4)
# ---------------------------------------------------------------------------
# write-rule.sh now accepts `ask` as a third list target, creates fresh files
# with a v2 skeleton (all three arrays), and upgrades in-place v1 -> v2 the
# first time an `ask` write lands against a file. allow/deny writes against a
# v1 file deliberately keep the file at v1 so opting into v2 stays explicit.

@test "write-rule: ask write appends to ask[] on a fresh file" {
  [ ! -f "$(user_file)" ]
  run_write user ask '{"tool":"WebFetch","match":{"url":"^https?://unsafe\\."},"reason":"prompt first"}'
  [ "$status" -eq 0 ]
  [ -f "$(user_file)" ]
  # Skeleton is v2 with all three arrays; the ask rule landed in ask[].
  run jq -e '.version == 2
             and (.allow | length == 0)
             and (.deny  | length == 0)
             and (.ask   | length == 1)' "$(user_file)"
  [ "$status" -eq 0 ]
  run jq -r '.ask[0].tool' "$(user_file)"
  [ "$output" = "WebFetch" ]
  run jq -r '.ask[0].match.url' "$(user_file)"
  [ "$output" = '^https?://unsafe\.' ]
}

@test "write-rule: ask write appends to ask[] alongside existing allow/deny" {
  # Seed a v2 file with existing allow + deny rules.
  cat > "$(user_file)" <<'EOF'
{"version":2,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"ask":[],"deny":[{"tool":"Bash","match":{"command":"^rm"}}]}
EOF
  run_write user ask '{"tool":"WebFetch","match":{"url":"^https?://prompt\\."}}'
  [ "$status" -eq 0 ]
  run jq -r '.version' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.ask[0].tool' "$(user_file)"
  [ "$output" = "WebFetch" ]
}

@test "write-rule: multiple ask appends accumulate in order" {
  run_write user ask '{"tool":"WebFetch","match":{"url":"^https?://a\\."}}'
  [ "$status" -eq 0 ]
  run_write user ask '{"tool":"WebFetch","match":{"url":"^https?://b\\."}}'
  [ "$status" -eq 0 ]
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.ask[0].match.url' "$(user_file)"
  [ "$output" = '^https?://a\.' ]
  run jq -r '.ask[1].match.url' "$(user_file)"
  [ "$output" = '^https?://b\.' ]
}

@test "write-rule: first ask write upgrades v1 file to v2 in place" {
  # Seed an explicit v1 file with existing allow/deny rules. The ask[] key
  # is absent, as it would be for any real v1 file in the wild.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[{"tool":"Bash","match":{"command":"^rm"}}]}
EOF
  run_write user ask '{"tool":"WebFetch","match":{"url":"^https?://unsafe\\."}}'
  [ "$status" -eq 0 ]
  # File is upgraded to v2. Existing allow/deny rules are preserved
  # unchanged; ask[] now exists with exactly the new rule.
  run jq -e '.version == 2
             and (.allow | length == 1)
             and (.allow[0].match.command == "^ls")
             and (.deny  | length == 1)
             and (.deny[0].match.command == "^rm")
             and (.ask   | length == 1)
             and (.ask[0].tool == "WebFetch")' "$(user_file)"
  [ "$status" -eq 0 ]
}

@test "write-rule: v1 -> v2 upgrade preserves arbitrary extra top-level keys" {
  # A v1 file that carries an extra field (for example a future annotation
  # we do not want to silently drop). The upgrade must preserve everything
  # other than the bumped version and the added ask[] key.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[],"_note":"keep me"}
EOF
  run_write user ask '{"tool":"WebFetch","match":{"url":"^https?://x\\."}}'
  [ "$status" -eq 0 ]
  run jq -r '._note' "$(user_file)"
  [ "$output" = "keep me" ]
  run jq -r '.version' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "1" ]
}

@test "write-rule: allow write against a v1 file does NOT upgrade to v2" {
  # Seed an explicit v1 file. An allow write must leave the version at 1
  # and must NOT synthesize an ask[] key. Users who never opt into ask
  # keep their v1 files byte-stable.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[]}
EOF
  run_write user allow '{"tool":"Bash","match":{"command":"^pwd"}}'
  [ "$status" -eq 0 ]
  run jq -r '.version' "$(user_file)"
  [ "$output" = "1" ]
  # ask[] key must be absent on the still-v1 file.
  run jq -e 'has("ask") | not' "$(user_file)"
  [ "$status" -eq 0 ]
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "1" ]
}

@test "write-rule: deny write against a v1 file does NOT upgrade to v2" {
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[]}
EOF
  run_write user deny '{"tool":"Bash","match":{"command":"^rm\\s+-rf"}}'
  [ "$status" -eq 0 ]
  run jq -r '.version' "$(user_file)"
  [ "$output" = "1" ]
  run jq -e 'has("ask") | not' "$(user_file)"
  [ "$status" -eq 0 ]
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "1" ]
}

@test "write-rule: invalid list value block still rejected alongside ask support" {
  # Regression: extending the list vocabulary to {allow,deny,ask} must not
  # accidentally accept arbitrary strings.
  run_write user block '{"tool":"Bash"}'
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Cross-list conflict prevention on ask writes (verifier rejection surfaces
# from the write-rule.sh wrapper; backup is restored).
# ---------------------------------------------------------------------------

@test "write-rule: conflict ask-after-allow is rejected and rolled back" {
  # Seed an allow rule, then try to write the identical rule into ask[].
  # The verifier must report a three-way conflict and the wrapper must roll
  # back to the original file byte-for-byte.
  cat > "$(user_file)" <<'EOF'
{"version":2,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"ask":[],"deny":[]}
EOF
  ORIG="$(cat "$(user_file)")"
  run bash -c "bash '$WRITE' user ask '{\"tool\":\"Bash\",\"match\":{\"command\":\"^ls\"}}' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflict"* ]]
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

@test "write-rule: conflict ask-after-deny is rejected and rolled back" {
  cat > "$(user_file)" <<'EOF'
{"version":2,"allow":[],"ask":[],"deny":[{"tool":"Bash","match":{"command":"^rm"}}]}
EOF
  ORIG="$(cat "$(user_file)")"
  run bash -c "bash '$WRITE' user ask '{\"tool\":\"Bash\",\"match\":{\"command\":\"^rm\"}}' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflict"* ]]
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

@test "write-rule: conflict allow-after-ask is rejected and rolled back" {
  cat > "$(user_file)" <<'EOF'
{"version":2,"allow":[],"ask":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  ORIG="$(cat "$(user_file)")"
  run bash -c "bash '$WRITE' user allow '{\"tool\":\"Bash\",\"match\":{\"command\":\"^ls\"}}' 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflict"* ]]
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}
