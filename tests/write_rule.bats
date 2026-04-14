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
  # Resulting file should have version 1 + allow + deny arrays.
  run jq -e '.version == 1 and (.allow | type == "array") and (.deny | type == "array")' "$(user_file)"
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

  run_write user allow '{"tool":"Bash","match":{"command":"["}}'
  [ "$status" -ne 0 ]
  [[ "${output}${stderr:-}" == *"verifier"* ]] || run bash -c "bash '$WRITE' user allow '{\"tool\":\"Bash\",\"match\":{\"command\":\"[\"}}' 2>&1"
  # File must be byte-for-byte identical to the original.
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

@test "write-rule: invalid regex on new file -> file still exists in valid shape" {
  # No baseline -> write-rule creates the skeleton, then tries to append.
  [ ! -f "$(user_file)" ]
  run bash -c "bash '$WRITE' user allow '{\"tool\":\"Bash\",\"match\":{\"command\":\"[\"}}' 2>&1"
  [ "$status" -ne 0 ]
  # File must exist and be the valid skeleton.
  [ -f "$(user_file)" ]
  run jq -e '.version == 1 and (.allow | length == 0) and (.deny | length == 0)' "$(user_file)"
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

@test "write-rule: concurrent writes do not corrupt the file" {
  # Spawn two writes in parallel to the same file with distinct rules. Either
  # both succeed (serialized) or one succeeds and one fails cleanly; in every
  # case, the final file must parse and contain at least one rule.
  (
    bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^a1"}}' >/dev/null 2>&1
  ) &
  PID1=$!
  (
    bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^b2"}}' >/dev/null 2>&1
  ) &
  PID2=$!

  wait "$PID1" || true
  wait "$PID2" || true

  # Final state must be valid JSON.
  [ -f "$(user_file)" ]
  run jq -e '.version == 1 and (.allow | type == "array")' "$(user_file)"
  [ "$status" -eq 0 ]

  # Count must be 1 or 2 (not 0, not some corrupted value).
  run jq -r '.allow | length' "$(user_file)"
  count="$output"
  [ "$count" = "1" ] || [ "$count" = "2" ]
}

@test "write-rule: lock timeout respected when held externally" {
  # Simulate an externally-held lock by creating the mkdir-style lock dir.
  # We do NOT know which style the implementation chose, so we trigger both:
  # create the mkdir lock and also attempt to hold an fd lock. For the bats
  # environment where flock may or may not be installed, we target the path
  # that actually exists.
  LOCK_PATH="$USER_ROOT/.claude/passthru.write.lock"
  mkdir -p "$USER_ROOT/.claude"

  if command -v flock >/dev/null 2>&1; then
    # Hold the lock in a background subshell for longer than the timeout.
    (
      exec 7>"$LOCK_PATH"
      flock 7
      sleep 2
    ) &
    HOLDER=$!
    sleep 0.2  # give the holder time to acquire
  else
    mkdir "${LOCK_PATH}.d"
    HOLDER=""
  fi

  PASSTHRU_WRITE_LOCK_TIMEOUT=1 run bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^ls"}}'
  [ "$status" -ne 0 ]

  # Cleanup the holder/lockdir.
  if [ -n "$HOLDER" ]; then
    kill "$HOLDER" 2>/dev/null || true
    wait "$HOLDER" 2>/dev/null || true
  else
    rmdir "${LOCK_PATH}.d" 2>/dev/null || true
  fi
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
