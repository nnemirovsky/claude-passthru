#!/usr/bin/env bats

# tests/verifier.bats
# Covers scripts/verify.sh across all 6 checks, flags, exit codes, and edge
# cases. Uses synthetic PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR roots so real
# ~/.claude is never touched.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VERIFY="$REPO_ROOT/scripts/verify.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures"

  TMP="$(mktemp -d -t passthru-verify-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

place() {
  # $1 target path, $2 fixture name
  cp "$FIXTURES/$2" "$1"
}

run_verify() {
  run bash "$VERIFY" "$@"
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "verifier: no files at all -> exit 0 'no rules'" {
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"no rules"* ]]
}

@test "verifier: no files, --format json -> status ok, rules 0, files 0" {
  run_verify --format json
  [ "$status" -eq 0 ]
  run jq -e '.status == "ok" and .rules == 0 and .files == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "verifier: no files, --quiet -> no stdout, exit 0" {
  run_verify --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verifier: valid single file -> exit 0 with OK line" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]"* ]]
  [[ "$output" == *"rules"* ]]
}

@test "verifier: one valid + one invalid file -> exit 1 only naming bad file" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  place "$PROJ_ROOT/.claude/passthru.json" "invalid-regex.json"
  # Run with stderr merged so we can assert on the [ERR] line directly.
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  # Bad file is named in the error.
  [[ "$output" == *"$PROJ_ROOT"* ]]
  # Good file is NOT named with a `:`-suffixed jq path (i.e. no error against it).
  if printf '%s' "$output" | grep -q "$USER_ROOT/.claude/passthru.json:"; then
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Check 1: parse
# ---------------------------------------------------------------------------

@test "check 1 parse: malformed JSON -> error names file + jq error" {
  printf 'not-json{' > "$USER_ROOT/.claude/passthru.json"
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$USER_ROOT/.claude/passthru.json"* ]]
  [[ "$output" == *"parse"* ]]
}

@test "check 1 parse: empty file treated as empty rules set" {
  : > "$USER_ROOT/.claude/passthru.json"
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]"* ]]
}

# ---------------------------------------------------------------------------
# Check 2: schema
# ---------------------------------------------------------------------------

@test "check 2 schema: rule missing tool and match -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"reason":"no tool, no match"}],"deny":[]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema"* ]]
  [[ "$output" == *"tool"* ]] || [[ "$output" == *"match"* ]]
}

@test "check 2 schema: unsupported version -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":99,"allow":[],"deny":[]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version"* ]]
}

@test "check 2 schema: non-string tool -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":123}],"deny":[]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be string"* ]]
}

@test "check 2 schema: match not object -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":"not-an-object"}],"deny":[]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"match"* ]]
  [[ "$output" == *"object"* ]]
}

# ---------------------------------------------------------------------------
# Check 3: regex compile
# ---------------------------------------------------------------------------

@test "check 3 regex: invalid regex in tool -> error with file + index" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"[","reason":"broken"}],"deny":[]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"regex"* ]]
  [[ "$output" == *"$USER_ROOT/.claude/passthru.json"* ]]
  [[ "$output" == *"rule 0"* ]]
}

@test "check 3 regex: invalid regex in match.* -> error names the key" {
  place "$USER_ROOT/.claude/passthru.json" "invalid-regex.json"
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"match.command"* ]]
  [[ "$output" == *"regex"* ]]
}

# ---------------------------------------------------------------------------
# Check 4: duplicates (across scopes)
# ---------------------------------------------------------------------------

@test "check 4 duplicates: same rule in two scopes -> warn, exit 0" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"duplicate"* ]]
}

@test "check 4 duplicates: same rule within one file -> warn" {
  place "$USER_ROOT/.claude/passthru.json" "duplicate-rules.json"
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"duplicate"* ]]
}

# ---------------------------------------------------------------------------
# Check 5: deny/allow conflict
# ---------------------------------------------------------------------------

@test "check 5 conflict: identical rule in allow and deny -> error, exit 1" {
  place "$USER_ROOT/.claude/passthru.json" "conflicting-rules.json"
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
}

@test "check 5 conflict: cross-scope identical allow + deny -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[],"deny":[{"tool":"Bash","match":{"command":"^ls"}}]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
}

# ---------------------------------------------------------------------------
# Check 6: shadowing
# ---------------------------------------------------------------------------

@test "check 6 shadowing: duplicate at later index -> warn, naming indices" {
  place "$USER_ROOT/.claude/passthru.json" "shadowed-rule.json"
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"shadowing:"* ]]
  # Explicit form: "rule N shadowed by earlier identical rule at index M".
  # Accept any N>=1 and M<N (fixture has 3 identical rules at indices 0,1,2).
  [[ "$output" =~ rule\ [0-9]+\ shadowed\ by ]]
}

# ---------------------------------------------------------------------------
# Schema v2: ask[] array
# ---------------------------------------------------------------------------

@test "schema v2: version 2 with ask[] is accepted" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [{"tool":"Bash","match":{"command":"^ls"}}],
  "deny": [],
  "ask": [{"tool":"WebFetch","match":{"url":"^https?://"}}]
}
EOF
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]"* ]]
}

@test "schema v2: malformed ask rule (no tool, no match) -> error names ask list" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [{"reason":"broken"}]
}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema"* ]]
  # Path must point into .ask[0] so the user knows which array to fix.
  [[ "$output" == *".ask[0]"* ]]
}

@test "schema v2: invalid regex in ask[] tool -> error names ask list" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [{"tool":"[","reason":"bad regex"}]
}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"regex"* ]]
  [[ "$output" == *".ask[0]"* ]]
}

@test "schema v2: unsupported version (v3) -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":3,"allow":[],"deny":[]}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version"* ]]
}

@test "schema v1: ask[] key in v1 file is ignored (not validated as rules)" {
  # A v1 file that carries ask[] would trigger schema errors if validated,
  # but verify.sh drops ask[] on v1 (single source of truth with load_rules).
  # This keeps partial migrations from failing the verifier loudly.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [{"tool":"Bash","match":{"command":"^ls"}}],
  "deny": [],
  "ask": [{"reason":"would fail schema if validated"}]
}
EOF
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]"* ]]
}

# ---------------------------------------------------------------------------
# Check 5 triad: conflict across (allow, ask, deny)
# ---------------------------------------------------------------------------

@test "check 5 triad: conflict between ask[] and allow[] -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [{"tool":"Bash","match":{"command":"^ls"}}],
  "deny": [],
  "ask": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
  # Message must mention both lists so the user can locate the conflict.
  [[ "$output" == *"allow"* ]]
  [[ "$output" == *"ask"* ]]
}

@test "check 5 triad: conflict between ask[] and deny[] -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [{"tool":"Bash","match":{"command":"^ls"}}],
  "ask": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
  [[ "$output" == *"ask"* ]]
  [[ "$output" == *"deny"* ]]
}

@test "check 5 triad: cross-scope conflict ask (user) + deny (project) -> error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
}

@test "check 5 triad: same rule in all three lists -> single conflict error" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [{"tool":"Bash","match":{"command":"^ls"}}],
  "deny": [{"tool":"Bash","match":{"command":"^ls"}}],
  "ask": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict"* ]]
}

@test "check 5 triad: duplicate within ask[] in two scopes -> warn (plain duplicate)" {
  # Both scopes declare the same ask rule. This is a duplicate, not a conflict
  # (same list name on both sides).
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [{"tool":"Bash","match":{"command":"^ls"}}]
}
EOF
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"duplicate"* ]]
  # Not a conflict.
  if printf '%s' "$output" | grep -q 'conflict'; then
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Check 6 shadowing: ask[] array
# ---------------------------------------------------------------------------

@test "check 6 shadowing: duplicate within ask[] -> warn" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [
    {"tool":"Bash","match":{"command":"^gh api"},"reason":"first"},
    {"tool":"Bash","match":{"command":"^gh api"},"reason":"shadowed"}
  ]
}
EOF
  run_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"shadowing:"* ]]
  # The shadowing message must reference the ask list.
  [[ "$output" == *"ask"* ]]
  [[ "$output" =~ rule\ [0-9]+\ shadowed\ by ]]
}

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

@test "--strict: warnings turn into non-zero exit 2" {
  place "$USER_ROOT/.claude/passthru.json" "duplicate-rules.json"
  run_verify --strict
  [ "$status" -eq 2 ]
}

@test "--strict: clean input still exit 0" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify --strict
  [ "$status" -eq 0 ]
}

@test "--quiet: success prints nothing to stdout" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--quiet: errors still print (to stderr)" {
  place "$USER_ROOT/.claude/passthru.json" "invalid-regex.json"
  run bash -c "bash '$VERIFY' --quiet 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"regex"* ]]
}

@test "--scope user: ignores project files" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  # Broken file in project scope - should be ignored by --scope user.
  place "$PROJ_ROOT/.claude/passthru.json" "invalid-regex.json"
  run_verify --scope user
  [ "$status" -eq 0 ]
}

@test "--scope project: ignores user files" {
  place "$USER_ROOT/.claude/passthru.json" "invalid-regex.json"
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  run_verify --scope project
  [ "$status" -eq 0 ]
}

@test "--scope invalid -> exit 1 with usage error" {
  run_verify --scope foo
  [ "$status" -eq 1 ]
}

@test "--scope=user (equals form) ignores project files" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"^ls"}}],"deny":[]}
EOF
  place "$PROJ_ROOT/.claude/passthru.json" "invalid-regex.json"
  run_verify --scope=user
  [ "$status" -eq 0 ]
}

@test "--format=json (equals form) emits valid JSON" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify --format=json
  [ "$status" -eq 0 ]
  run jq -e '.status == "ok"' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "--format json: clean run emits valid JSON with counts" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify --format json
  [ "$status" -eq 0 ]
  # Must be valid JSON with expected fields.
  run jq -e '.status == "ok" and (.rules | type == "number") and (.files | type == "number") and (.errors | length == 0) and (.warnings | length == 0)' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "--format json: error run emits valid JSON with errors array" {
  place "$USER_ROOT/.claude/passthru.json" "invalid-regex.json"
  run_verify --format json
  [ "$status" -eq 1 ]
  run jq -e '.status == "error" and (.errors | length >= 1) and (.errors[0].severity == "error")' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "--format json: warning run emits status warn" {
  place "$USER_ROOT/.claude/passthru.json" "duplicate-rules.json"
  run_verify --format json
  [ "$status" -eq 0 ]
  run jq -e '.status == "warn" and (.warnings | length >= 1)' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "--format invalid -> exit 1" {
  run_verify --format xml
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------

@test "exit 0: clean" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify
  [ "$status" -eq 0 ]
}

@test "exit 1: any error present" {
  place "$USER_ROOT/.claude/passthru.json" "conflicting-rules.json"
  run_verify
  [ "$status" -eq 1 ]
}

@test "exit 2: warnings only with --strict" {
  place "$USER_ROOT/.claude/passthru.json" "shadowed-rule.json"
  run_verify --strict
  [ "$status" -eq 2 ]
}

@test "exit 1 wins over warnings in mixed output" {
  # duplicate rule + invalid regex -> error wins.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool":"Bash","match":{"command":"^ls"}},
    {"tool":"Bash","match":{"command":"^ls"}},
    {"tool":"Bash","match":{"command":"["}}
  ],
  "deny": []
}
EOF
  run_verify
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Report format
# ---------------------------------------------------------------------------

@test "report format: plain success message" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_verify
  [[ "$output" == *"[OK]"* ]]
  [[ "$output" == *"rules"* ]]
  [[ "$output" == *"files"* ]]
}

@test "report format: plain failure includes severity + file + message" {
  place "$USER_ROOT/.claude/passthru.json" "invalid-regex.json"
  run bash -c "bash '$VERIFY' 2>&1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[ERR]"* ]]
  [[ "$output" == *"$USER_ROOT/.claude/passthru.json"* ]]
}
