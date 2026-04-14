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
  run jq -e '.version == 1 and (.allow | length == 0) and (.deny | length == 0)' <<<"$output"
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
  run validate_rules '{"version":2,"allow":[],"deny":[]}'
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"version"* ]] || [[ "$output" == *"version"* ]]
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
