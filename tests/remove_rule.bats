#!/usr/bin/env bats

# tests/remove_rule.bats
# End-to-end coverage for scripts/remove-rule.sh. Hermetic via
# PASSTHRU_USER_HOME + PASSTHRU_PROJECT_DIR so real ~/.claude is never
# touched. Exercises: happy-path removal preserving order, index
# semantics within (scope, list), refusal to touch imported files,
# invalid-arg handling, verifier rollback, and concurrent add+remove
# serialization.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REMOVE="$REPO_ROOT/scripts/remove-rule.sh"
  WRITE="$REPO_ROOT/scripts/write-rule.sh"

  TMP="$(mktemp -d -t passthru-remove.XXXXXX)"
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

user_imported_file() {
  printf '%s/.claude/passthru.imported.json\n' "$USER_ROOT"
}

proj_file() {
  printf '%s/.claude/passthru.json\n' "$PROJ_ROOT"
}

proj_imported_file() {
  printf '%s/.claude/passthru.imported.json\n' "$PROJ_ROOT"
}

run_remove() {
  run bash "$REMOVE" "$@"
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

seed_user_authored() {
  cat > "$(user_file)" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "Bash", "match": {"command": "^ls"}, "reason": "list"},
    {"tool": "Bash", "match": {"command": "^pwd"}, "reason": "pwd"},
    {"tool": "Bash", "match": {"command": "^gh"}, "reason": "gh"}
  ],
  "deny": [
    {"tool": "Bash", "match": {"command": "rm -rf /"}, "reason": "safety"},
    {"tool": "Bash", "match": {"command": "^sudo "}, "reason": "no sudo"}
  ]
}
EOF
}

seed_user_imported() {
  cat > "$(user_imported_file)" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "Bash", "match": {"command": "^imp1"}}
  ],
  "deny": []
}
EOF
}

seed_project_authored() {
  cat > "$(proj_file)" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "Read", "match": {"file_path": "^/tmp/"}, "reason": "tmp reads"}
  ],
  "deny": [
    {"tool": "Bash", "match": {"command": "^curl"}, "reason": "no curl"}
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "remove: missing args -> exit 1 with usage" {
  run_remove
  [ "$status" -eq 1 ]
}

@test "remove: invalid scope -> exit 1" {
  seed_user_authored
  run_remove global allow 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid scope"* ]]
}

@test "remove: invalid list -> exit 1" {
  seed_user_authored
  run_remove user block 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid list"* ]]
}

@test "remove: non-numeric index -> exit 1" {
  seed_user_authored
  run_remove user allow abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "remove: zero index -> exit 1" {
  seed_user_authored
  run_remove user allow 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "remove: missing authored file -> exit 1" {
  [ ! -f "$(user_file)" ]
  run_remove user allow 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"authored rule file not found"* ]]
}

@test "remove: malformed authored file -> exit 1 without modification" {
  printf '{not valid' > "$(user_file)"
  ORIG="$(cat "$(user_file)")"
  run_remove user allow 1
  [ "$status" -eq 1 ]
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "remove: happy path removes authored allow rule at index 2" {
  seed_user_authored
  run_remove user allow 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed user/allow/2"* ]]
  # Success stdout includes a tool-summary.
  [[ "$output" == *"tool=Bash"* ]]
  [[ "$output" == *"command=^pwd"* ]]

  # Remaining allow list has 2 rules, in the right order (ls then gh).
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.allow[0].match.command' "$(user_file)"
  [ "$output" = "^ls" ]
  run jq -r '.allow[1].match.command' "$(user_file)"
  [ "$output" = "^gh" ]
  # Deny list is untouched.
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "2" ]
}

@test "remove: happy path removes authored deny rule at index 1" {
  seed_user_authored
  run_remove user deny 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed user/deny/1"* ]]
  # Allow list unchanged.
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "3" ]
  # Deny list shrunk to 1; remaining rule is the sudo one.
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.deny[0].match.command' "$(user_file)"
  [ "$output" = "^sudo " ]
}

@test "remove: happy path on project scope targets the project authored file" {
  seed_project_authored
  # Baseline: allow has 1, deny has 1.
  run jq -r '.allow | length' "$(proj_file)"
  [ "$output" = "1" ]
  run_remove project allow 1
  [ "$status" -eq 0 ]
  # Project file has 0 allow rules, 1 deny rule.
  run jq -r '.allow | length' "$(proj_file)"
  [ "$output" = "0" ]
  run jq -r '.deny | length' "$(proj_file)"
  [ "$output" = "1" ]
  # User file was not created or modified.
  [ ! -f "$(user_file)" ]
}

@test "remove: scope isolation - user remove does not touch project file" {
  seed_user_authored
  seed_project_authored
  ORIG_PROJ="$(cat "$(proj_file)")"
  run_remove user allow 1
  [ "$status" -eq 0 ]
  AFTER_PROJ="$(cat "$(proj_file)")"
  [ "$ORIG_PROJ" = "$AFTER_PROJ" ]
}

# ---------------------------------------------------------------------------
# Index semantics: within (scope, list, authored-source)
# ---------------------------------------------------------------------------

@test "remove: index references correct rule within scope+list authored group" {
  # Authored deny has 2 rules: [rm -rf, sudo]. Removing index 2 keeps
  # [rm -rf]. Index is 1-based, per-list, per-authored-file (not global).
  seed_user_authored
  run_remove user deny 2
  [ "$status" -eq 0 ]
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.deny[0].match.command' "$(user_file)"
  [ "$output" = "rm -rf /" ]
}

# ---------------------------------------------------------------------------
# Out-of-range
# ---------------------------------------------------------------------------

@test "remove: index past end of authored list -> exit 1" {
  seed_user_authored
  run_remove user allow 10
  [ "$status" -eq 1 ]
  [[ "$output" == *"out of range"* ]]
  # File untouched.
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "3" ]
}

@test "remove: index on empty authored list with no imported rules -> exit 1" {
  # User has only deny rules; allow is empty.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[{"tool":"Bash","match":{"command":"rm -rf"}}]}
EOF
  run_remove user allow 1
  [ "$status" -eq 1 ]
  # "nothing at index" path.
  [[ "$output" == *"nothing at index"* ]]
}

# ---------------------------------------------------------------------------
# Imported rules: refuse with the spec message
# ---------------------------------------------------------------------------

@test "remove: refuses to remove imported rule (user scope, allow)" {
  # Authored file has nothing; imported file has an allow rule. Attempting
  # to remove index 1 from allow must trip the imported-rule guard and exit
  # 1 with the spec's exact wording.
  cat > "$(user_file)" <<'EOF'
{"version":1,"allow":[],"deny":[]}
EOF
  seed_user_imported
  run_remove user allow 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot remove imported rule at user/allow/1"* ]]
  [[ "$output" == *"scripts/bootstrap.sh --write"* ]]
  # Imported file untouched.
  run jq -r '.allow | length' "$(user_imported_file)"
  [ "$output" = "1" ]
}

@test "remove: refuses imported-only when authored file is entirely missing" {
  # No authored file on disk at all. Remove must error, not crash.
  [ ! -f "$(user_file)" ]
  seed_user_imported
  run_remove user allow 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"authored rule file not found"* ]]
}

# ---------------------------------------------------------------------------
# Verifier failure scenario: simulate a rejection and confirm rollback
# ---------------------------------------------------------------------------

@test "remove: verifier failure -> exit 2 with file restored" {
  # Stub verify.sh under a fake plugin root so we control its exit code.
  FAKE_ROOT="$TMP/fake-root"
  mkdir -p "$FAKE_ROOT/hooks" "$FAKE_ROOT/scripts"
  cp "$REPO_ROOT/hooks/common.sh" "$FAKE_ROOT/hooks/common.sh"
  cat > "$FAKE_ROOT/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
# Fail after removal so we test the rollback path.
printf 'stub verify failure\n' >&2
exit 1
SH
  chmod +x "$FAKE_ROOT/scripts/verify.sh"

  seed_user_authored
  ORIG="$(cat "$(user_file)")"

  CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" run bash "$REMOVE" user allow 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"rolled back"* ]]
  [[ "$output" == *"stub verify failure"* ]]

  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

# ---------------------------------------------------------------------------
# Concurrent add + remove serialize via the shared lock
# ---------------------------------------------------------------------------

@test "remove: concurrent add+remove serialize via the shared lock" {
  # Start with a known 3-rule allow list. Launch add and remove in parallel.
  # The lock must serialize them; both must succeed. Final state must still
  # be a valid JSON file.
  seed_user_authored

  (
    bash "$WRITE" user allow '{"tool":"Bash","match":{"command":"^new1"}}' >/dev/null 2>&1
  ) &
  PID1=$!
  (
    bash "$REMOVE" user allow 1 >/dev/null 2>&1
  ) &
  PID2=$!

  rc1=0
  rc2=0
  wait "$PID1" || rc1=$?
  wait "$PID2" || rc2=$?

  # Both must exit 0 (serialization, not failure).
  [ "$rc1" -eq 0 ]
  [ "$rc2" -eq 0 ]

  [ -f "$(user_file)" ]
  run jq -e '.version == 1 and (.allow | type == "array") and (.deny | type == "array")' "$(user_file)"
  [ "$status" -eq 0 ]

  # Whatever the interleaving, final allow count is deterministic: started
  # with 3, added 1, removed 1 -> 3.
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "3" ]
  # Deny list unchanged at 2.
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "2" ]
}

@test "remove: lock timeout respected when held externally" {
  seed_user_authored
  LOCK_PATH="$USER_ROOT/.claude/passthru.write.lock"
  mkdir -p "$USER_ROOT/.claude"
  mkdir "${LOCK_PATH}.d"

  PASSTHRU_WRITE_LOCK_TIMEOUT=1 run bash "$REMOVE" user allow 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to acquire lock"* ]]

  rmdir "${LOCK_PATH}.d" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Signal safety: SIGTERM between mv and verifier must leave the file restored
# ---------------------------------------------------------------------------

@test "remove: SIGTERM between mv-target and verifier -> file rolled back" {
  # Mirror of write_rule.bats's post-mv-pre-verify signal test: the STATE
  # machine in cleanup() must roll back BACKUP over TARGET when a signal
  # interrupts the post-mv window, otherwise the file gets left with an
  # unverified in-memory state.
  FAKE_ROOT="$TMP/fake-sig-root"
  mkdir -p "$FAKE_ROOT/hooks" "$FAKE_ROOT/scripts"
  cp "$REPO_ROOT/hooks/common.sh" "$FAKE_ROOT/hooks/common.sh"
  cat > "$FAKE_ROOT/scripts/verify.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKE_ROOT/scripts/verify.sh"

  INSTR_REMOVE="$TMP/remove-rule-instr.sh"
  awk '
    /^mv "\$TMPOUT" "\$TARGET"$/ { print; print "sleep 0.6"; next }
    { print }
  ' "$REMOVE" > "$INSTR_REMOVE"
  chmod +x "$INSTR_REMOVE"

  seed_user_authored
  ORIG="$(cat "$(user_file)")"

  CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
    bash "$INSTR_REMOVE" user allow 1 >/dev/null 2>&1 &
  wpid=$!
  (sleep 0.3; kill -TERM "$wpid" 2>/dev/null || true) &
  killer_pid=$!

  set +e
  wait "$wpid"
  wrc=$?
  set -e
  wait "$killer_pid" 2>/dev/null || true

  # Signal-driven exit.
  [ "$wrc" -ne 0 ]
  # File content restored byte-for-byte.
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
}

# ---------------------------------------------------------------------------
# Success-message tool summary for an MCP-namespace rule (no match block)
# ---------------------------------------------------------------------------

@test "remove: success message for MCP-namespace rule reports tool only" {
  cat > "$(user_file)" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "^mcp__gemini-cli__", "reason": "gemini mcp"}
  ],
  "deny": []
}
EOF
  run_remove user allow 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed user/allow/1"* ]]
  [[ "$output" == *"tool=^mcp__gemini-cli__"* ]]
}

# ---------------------------------------------------------------------------
# Preserves existing rules and reason fields
# ---------------------------------------------------------------------------

@test "remove: reason field on surviving rules is preserved byte-for-byte" {
  seed_user_authored
  # Remove middle rule; first and third should retain their reason fields.
  run_remove user allow 2
  [ "$status" -eq 0 ]
  run jq -r '.allow[0].reason' "$(user_file)"
  [ "$output" = "list" ]
  run jq -r '.allow[1].reason' "$(user_file)"
  [ "$output" = "gh" ]
}

# ---------------------------------------------------------------------------
# Test project-imported refusal path
# ---------------------------------------------------------------------------

@test "remove: refuses to remove imported rule at project scope" {
  cat > "$(proj_file)" <<'EOF'
{"version":1,"allow":[],"deny":[]}
EOF
  cat > "$(proj_imported_file)" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^proj-imp"}}],"deny":[]}
EOF
  run_remove project allow 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot remove imported rule at project/allow/1"* ]]
  # Imported file untouched.
  run jq -r '.allow | length' "$(proj_imported_file)"
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# ask[] removal support (schema v2)
# ---------------------------------------------------------------------------

seed_user_authored_with_ask() {
  cat > "$(user_file)" <<'EOF'
{
  "version": 2,
  "allow": [
    {"tool": "Bash", "match": {"command": "^ls"}, "reason": "list"}
  ],
  "ask": [
    {"tool": "WebFetch", "match": {"url": "^https?://unsafe\\."}, "reason": "unsafe"},
    {"tool": "Bash", "match": {"command": "^gh "}, "reason": "prompt on gh"},
    {"tool": "Read", "match": {"file_path": "^/etc/"}, "reason": "etc reads"}
  ],
  "deny": [
    {"tool": "Bash", "match": {"command": "rm -rf /"}, "reason": "safety"}
  ]
}
EOF
}

@test "remove: happy path removes authored ask rule at index 2" {
  seed_user_authored_with_ask
  run_remove user ask 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed user/ask/2"* ]]
  # Success stdout includes a tool-summary for the middle ask rule.
  [[ "$output" == *"tool=Bash"* ]]
  [[ "$output" == *"command=^gh "* ]]

  # Remaining ask list has 2 rules, in the right order (unsafe then etc).
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "2" ]
  run jq -r '.ask[0].match.url' "$(user_file)"
  [ "$output" = "^https?://unsafe\\." ]
  run jq -r '.ask[1].match.file_path' "$(user_file)"
  [ "$output" = "^/etc/" ]
  # Allow and deny lists untouched.
  run jq -r '.allow | length' "$(user_file)"
  [ "$output" = "1" ]
  run jq -r '.deny | length' "$(user_file)"
  [ "$output" = "1" ]
  # Version stays v2.
  run jq -r '.version' "$(user_file)"
  [ "$output" = "2" ]
}

@test "remove: removes first authored ask rule (index 1) preserving tail" {
  seed_user_authored_with_ask
  run_remove user ask 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed user/ask/1"* ]]
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "2" ]
  # Head removed; ^gh slides into index 0, etc into index 1.
  run jq -r '.ask[0].match.command' "$(user_file)"
  [ "$output" = "^gh " ]
}

@test "remove: removes last authored ask rule (index 3) and shrinks list" {
  seed_user_authored_with_ask
  run_remove user ask 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed user/ask/3"* ]]
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "2" ]
  # Tail removed; last element is now the "prompt on gh" rule.
  run jq -r '.ask[-1].match.command' "$(user_file)"
  [ "$output" = "^gh " ]
}

@test "remove: ask index past end of authored list -> exit 1" {
  seed_user_authored_with_ask
  run_remove user ask 99
  [ "$status" -eq 1 ]
  [[ "$output" == *"out of range"* ]]
  # File untouched.
  run jq -r '.ask | length' "$(user_file)"
  [ "$output" = "3" ]
}

@test "remove: --list ask on v1 file (no ask array) fails gracefully" {
  # Classic v1 file, no ask[] key at all. Attempting to remove from ask[]
  # must error out cleanly (the same 'nothing at index' path used for empty
  # lists) rather than crashing or silently promoting the schema to v2.
  cat > "$(user_file)" <<'EOF'
{
  "version": 1,
  "allow": [{"tool": "Bash", "match": {"command": "^ls"}}],
  "deny": []
}
EOF
  ORIG="$(cat "$(user_file)")"
  run_remove user ask 1
  [ "$status" -eq 1 ]
  # The imported file does not exist either, so we hit the 'nothing at index'
  # path rather than the imported-rule-refusal path.
  [[ "$output" == *"nothing at index"* ]]
  # File must not be mutated.
  AFTER="$(cat "$(user_file)")"
  [ "$ORIG" = "$AFTER" ]
  # Version stayed at 1 -- no silent schema promotion on a failed remove.
  run jq -r '.version' "$(user_file)"
  [ "$output" = "1" ]
  run jq -e 'has("ask") | not' "$(user_file)"
  [ "$status" -eq 0 ]
}

@test "remove: refuses to remove imported ask rule (user scope)" {
  # Authored file has no ask rules; imported file has one. Remove must
  # trip the imported-rule guard and exit 1 with the spec wording.
  cat > "$(user_file)" <<'EOF'
{"version":2,"allow":[],"ask":[],"deny":[]}
EOF
  cat > "$(user_imported_file)" <<'EOF'
{
  "version": 2,
  "allow": [],
  "ask": [
    {"tool": "WebFetch", "match": {"url": "^https?://"}, "reason": "imported ask"}
  ],
  "deny": []
}
EOF
  run_remove user ask 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot remove imported rule at user/ask/1"* ]]
  [[ "$output" == *"scripts/bootstrap.sh --write"* ]]
  # Imported file untouched.
  run jq -r '.ask | length' "$(user_imported_file)"
  [ "$output" = "1" ]
}

@test "remove: invalid list value 'block' still rejected (ask is added to the allowed set)" {
  # Sanity: the allowed-list set is now {allow, deny, ask}. Anything else
  # still errors out. Specifically verify ask is accepted and the error
  # message advertises the full triad.
  seed_user_authored_with_ask
  run_remove user block 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid list"* ]]
  [[ "$output" == *"allow|deny|ask"* ]]
}
