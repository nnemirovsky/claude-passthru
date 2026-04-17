#!/usr/bin/env bats

# tests/common_load.bats
# Validates hooks/common.sh load_rules and validate_rules helpers.
# Uses synthetic PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR directories so real
# ~/.claude is never touched during the test run.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$REPO_ROOT/tests/fixtures"

  # Synthetic scope roots: each test gets its own tmpdir.
  TMP="$(mktemp -d -t passthru-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"

  # Source the lib fresh for each test.
  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Helper: place a fixture into a scope file.
#   $1 = scope file (absolute path)
#   $2 = fixture name under tests/fixtures/
place() {
  cp "$FIXTURES/$2" "$1"
}

# ---------------------------------------------------------------------------
# load_rules
# ---------------------------------------------------------------------------

@test "load_rules emits empty skeleton when no files exist" {
  run load_rules
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Merged output is always emitted as v2 (superset of v1), with empty
  # allow/deny/ask arrays when no files contribute any rules.
  run jq -e '.version == 2 and (.allow | length == 0) and (.deny | length == 0) and (.ask | length == 0)' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "load_rules reads user-only authored file" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "2" ]
  run jq -r '.deny | length' <<<"$merged"
  [ "$output" = "1" ]
  run jq -r '.allow[0].tool' <<<"$merged"
  [ "$output" = "Bash" ]
}

@test "load_rules reads project-only authored file" {
  place "$PROJ_ROOT/.claude/passthru.json" "project-only.json"
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "2" ]
  run jq -r '.allow[0].tool' <<<"$merged"
  [ "$output" = "Read" ]
}

@test "load_rules merges user + project authored (user first, project second)" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  place "$PROJ_ROOT/.claude/passthru.json" "both-scopes.json"
  merged="$(load_rules)"
  # user-only has 2 allow + 1 deny, both-scopes has 1 allow + 1 deny -> 3 + 2
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "3" ]
  run jq -r '.deny | length' <<<"$merged"
  [ "$output" = "2" ]
  # Ordering: user-authored first entry comes before project-authored first entry.
  run jq -r '.allow[0].reason' <<<"$merged"
  [ "$output" = "safe read-only listing" ]
  run jq -r '.allow[2].reason' <<<"$merged"
  [ "$output" = "gh api repo calls" ]
}

@test "load_rules merges imported + authored in the same scope (user)" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  place "$USER_ROOT/.claude/passthru.imported.json" "imported-and-authored.json"
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "3" ]
  # Authored first, imported second (fixed order per load_rules).
  run jq -r '.allow[0].reason' <<<"$merged"
  [ "$output" = "safe read-only listing" ]
  run jq -r '.allow[2].reason' <<<"$merged"
  [ "$output" = "imported from settings" ]
}

@test "load_rules full four-file merge preserves fixed scope order" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  place "$USER_ROOT/.claude/passthru.imported.json" "imported-and-authored.json"
  place "$PROJ_ROOT/.claude/passthru.json" "project-only.json"
  place "$PROJ_ROOT/.claude/passthru.imported.json" "both-scopes.json"
  merged="$(load_rules)"

  # Order: user-authored(2) + user-imported(1) + project-authored(2) + project-imported(1) = 6 allow
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "6" ]
  run jq -r '.allow[0].reason' <<<"$merged"
  [ "$output" = "safe read-only listing" ]      # user-authored[0]
  run jq -r '.allow[2].reason' <<<"$merged"
  [ "$output" = "imported from settings" ]      # user-imported[0]
  run jq -r '.allow[3].reason' <<<"$merged"
  [ "$output" = "project source tree" ]          # project-authored[0]
  run jq -r '.allow[5].reason' <<<"$merged"
  [ "$output" = "gh api repo calls" ]            # project-imported[0]
}

@test "load_rules deny ordering preserved across four files" {
  # user-only has 1 deny, both-scopes has 1 deny. Place so user->deny[0], proj->deny[1].
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  place "$PROJ_ROOT/.claude/passthru.imported.json" "both-scopes.json"
  merged="$(load_rules)"
  run jq -r '.deny | length' <<<"$merged"
  [ "$output" = "2" ]
  run jq -r '.deny[0].reason' <<<"$merged"
  [ "$output" = "never rm -rf /" ]
  run jq -r '.deny[1].reason' <<<"$merged"
  [ "$output" = "no sudo in project shells" ]
}

@test "load_rules skips missing files silently" {
  # Only project file present; user files do not exist.
  place "$PROJ_ROOT/.claude/passthru.json" "project-only.json"
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "2" ]
}

@test "load_rules treats empty file as empty ruleset" {
  : > "$USER_ROOT/.claude/passthru.json"   # empty file
  place "$PROJ_ROOT/.claude/passthru.json" "project-only.json"
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "2" ]   # only project rules
}

@test "load_rules fails non-zero on malformed JSON and identifies the file" {
  echo '{ not json' > "$USER_ROOT/.claude/passthru.json"
  run load_rules
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"$USER_ROOT/.claude/passthru.json"* ]] || [[ "$output" == *"$USER_ROOT/.claude/passthru.json"* ]]
}

@test "load_rules tolerates file missing .allow or .deny keys" {
  # Valid JSON but minimal shape.
  echo '{}' > "$USER_ROOT/.claude/passthru.json"
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "0" ]
  run jq -r '.deny | length' <<<"$merged"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Schema v2: ask[] array
# ---------------------------------------------------------------------------

@test "load_rules: v1 file still loads as before (ask-rule absent in output)" {
  # user-only.json is v1 with no ask[] key. load_rules must emit
  # an empty ask[] in the merged output.
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  merged="$(load_rules)"
  run jq -r '.version' <<<"$merged"
  [ "$output" = "2" ]   # merged output is always v2 (superset).
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "2" ]
  run jq -r '.deny | length' <<<"$merged"
  [ "$output" = "1" ]
  # Crucially: ask[] is present and empty.
  run jq -r '.ask | length' <<<"$merged"
  [ "$output" = "0" ]
  # Must also pass validate_rules.
  run validate_rules "$merged"
  [ "$status" -eq 0 ]
}

@test "load_rules: v2 file with ask[] rules loads" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    {"tool":"Bash","match":{"command":"^ls"}}
  ],
  "deny": [
    {"tool":"Bash","match":{"command":"rm\\s+-rf\\s+/"}}
  ],
  "ask": [
    {"tool":"WebFetch","match":{"url":"^https?://unsafe\\."},"reason":"prompt on this domain"},
    {"tool":"^Bash$","match":{"command":"^gh api /repos/[^/]+/[^/]+/delete"}}
  ]
}
EOF
  merged="$(load_rules)"
  [ -n "$merged" ]
  run jq -r '.ask | length' <<<"$merged"
  [ "$output" = "2" ]
  run jq -r '.ask[0].reason' <<<"$merged"
  [ "$output" = "prompt on this domain" ]
  run jq -r '.ask[1].tool' <<<"$merged"
  [ "$output" = "^Bash$" ]
  run validate_rules "$merged"
  [ "$status" -eq 0 ]
}

@test "load_rules: v2 ask[] concatenates across scopes in fixed order" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [
    {"tool":"UserAsk","reason":"user scope"}
  ]
}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [
    {"tool":"ProjectAsk","reason":"project scope"}
  ]
}
EOF
  merged="$(load_rules)"
  # user-scope ask first, project-scope ask second.
  run jq -r '.ask | length' <<<"$merged"
  [ "$output" = "2" ]
  run jq -r '.ask[0].reason' <<<"$merged"
  [ "$output" = "user scope" ]
  run jq -r '.ask[1].reason' <<<"$merged"
  [ "$output" = "project scope" ]
}

@test "load_rules: v1 file with stray ask[] key -> ask entries are ignored" {
  # A v1 file that somehow carries an ask[] key (hand-edit, partial migration)
  # must NOT surface those entries. ask[] is v2-only.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [{"tool":"Bash","match":{"command":"^ls"}}],
  "deny": [],
  "ask": [{"tool":"WebFetch","reason":"ignored because v1"}]
}
EOF
  merged="$(load_rules)"
  run jq -r '.ask | length' <<<"$merged"
  [ "$output" = "0" ]
  # allow[] is still picked up normally.
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "1" ]
}

@test "load_rules: v2 file with malformed ask[] entry fails validation" {
  # Malformed rule = has neither tool nor match. load_rules still loads the
  # JSON, but validate_rules on the merged output must reject it.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [
    {"reason":"malformed, missing tool and match"}
  ]
}
EOF
  merged="$(load_rules)"
  [ -n "$merged" ]
  run validate_rules "$merged"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ask"* ]] || [[ "$output" == *"ask"* ]]
}

@test "load_rules: v3 file -> validate_rules on raw file returns error" {
  # Unknown future version must be rejected by validate_rules when it is
  # called on the raw file JSON (what verify.sh does per-file). load_rules
  # always rewrites the merged output to version 2 (strict superset),
  # so that path does not expose the raw version. The verifier's per-file
  # version check is covered separately in tests/verifier.bats.
  local raw='{"version":3,"allow":[],"deny":[]}'
  run validate_rules "$raw"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"version"* ]] || [[ "$output" == *"version"* ]]
}

@test "load_rules: mixed v1 + v2 files merge with only v2 contributing ask[]" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [{"tool":"Bash","match":{"command":"^ls"}}],
  "deny": []
}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [],
  "ask": [
    {"tool":"WebFetch","reason":"from v2 file"}
  ]
}
EOF
  merged="$(load_rules)"
  run jq -r '.allow | length' <<<"$merged"
  [ "$output" = "1" ]
  # Only the v2 project file's ask[] contributes.
  run jq -r '.ask | length' <<<"$merged"
  [ "$output" = "1" ]
  run jq -r '.ask[0].reason' <<<"$merged"
  [ "$output" = "from v2 file" ]
}

# ---------------------------------------------------------------------------
# validate_rules
# ---------------------------------------------------------------------------

@test "validate_rules accepts empty skeleton" {
  run validate_rules '{"version":1,"allow":[],"deny":[]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules accepts rule with tool only" {
  run validate_rules '{"version":1,"allow":[{"tool":"Bash"}],"deny":[]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules accepts rule with match only" {
  run validate_rules '{"version":1,"allow":[{"match":{"command":"^ls"}}],"deny":[]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules rejects rule with neither tool nor match" {
  run validate_rules '{"version":1,"allow":[{"reason":"whatever"}],"deny":[]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"at least one"* ]] || [[ "$output" == *"at least one"* ]]
}

@test "validate_rules rejects empty tool string" {
  run validate_rules '{"version":1,"allow":[{"tool":""}],"deny":[]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"tool"* ]] || [[ "$output" == *"tool"* ]]
}

@test "validate_rules rejects non-string match value" {
  run validate_rules '{"version":1,"allow":[{"tool":"Bash","match":{"command":42}}],"deny":[]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"match"* ]] || [[ "$output" == *"match"* ]]
}

@test "validate_rules rejects empty match value string" {
  run validate_rules '{"version":1,"allow":[{"tool":"Bash","match":{"command":""}}],"deny":[]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"non-empty"* ]] || [[ "$output" == *"non-empty"* ]]
}

@test "validate_rules rejects unsupported version" {
  # v3 is out of the accepted range (1 or 2). v2 is now accepted as a
  # superset of v1 with the optional ask[] array.
  run validate_rules '{"version":3,"allow":[],"deny":[]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"version"* ]] || [[ "$output" == *"version"* ]]
}

@test "validate_rules accepts version 2 with empty arrays" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules accepts version 2 without ask[] declared" {
  # ask[] is optional on v2 files. Missing ask[] is treated as an empty list.
  run validate_rules '{"version":2,"allow":[],"deny":[]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules accepts version 2 with valid ask rule" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[{"tool":"WebFetch","match":{"url":"^https?://"}}]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules rejects malformed ask rule on v2 (neither tool nor match)" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[{"reason":"no tool, no match"}]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"at least one"* ]] || [[ "$output" == *"at least one"* ]]
  # The error must name the offending list so users can locate it.
  [[ "$stderr" == *"ask"* ]] || [[ "$output" == *"ask"* ]]
}

@test "validate_rules rejects non-string tool on v2 ask rule" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[{"tool":42}]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ask"* ]] || [[ "$output" == *"ask"* ]]
}

@test "validate_rules rejects empty ask match value string on v2" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[{"tool":"Bash","match":{"command":""}}]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"non-empty"* ]] || [[ "$output" == *"non-empty"* ]]
}

@test "validate_rules rejects .ask that is not an array on v2" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":"oops"}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ask"* ]] || [[ "$output" == *"ask"* ]]
}

@test "validate_rules ignores ask[] on v1 (schema does not recognize it)" {
  # A v1 file that happens to include ask[] is still valid from the
  # validator's perspective: validate_rules only validates ask[] on v2.
  # Loader-side behavior (drop v1 ask[] entries) is covered in load_rules tests.
  run validate_rules '{"version":1,"allow":[],"deny":[],"ask":[{"reason":"would be invalid on v2"}]}'
  [ "$status" -eq 0 ]
}

@test "validate_rules rejects .allow that is not an array" {
  run validate_rules '{"version":1,"allow":"oops"}'
  [ "$status" -ne 0 ]
}

@test "validate_rules rejects .deny that is not an array" {
  run validate_rules '{"version":1,"deny":42}'
  [ "$status" -ne 0 ]
}

@test "validate_rules also checks deny rules (not just allow)" {
  run validate_rules '{"version":1,"allow":[],"deny":[{"match":{"command":""}}]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"deny"* ]] || [[ "$output" == *"deny"* ]]
}

@test "validate_rules rejects relative path in allowed_dirs" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[],"allowed_dirs":["relative/path"]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute path"* ]] || [[ "$stderr" == *"absolute path"* ]]
}

@test "validate_rules accepts absolute path in allowed_dirs" {
  run validate_rules '{"version":2,"allow":[],"deny":[],"ask":[],"allowed_dirs":["/opt/shared"]}'
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# combined: load_rules output always passes validate_rules
# ---------------------------------------------------------------------------

@test "load_rules output passes validate_rules for all four fixtures merged" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  place "$USER_ROOT/.claude/passthru.imported.json" "imported-and-authored.json"
  place "$PROJ_ROOT/.claude/passthru.json" "project-only.json"
  place "$PROJ_ROOT/.claude/passthru.imported.json" "both-scopes.json"
  merged="$(load_rules)"
  [ -n "$merged" ]
  run validate_rules "$merged"
  [ "$status" -eq 0 ]
}
