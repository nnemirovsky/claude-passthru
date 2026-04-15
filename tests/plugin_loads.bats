#!/usr/bin/env bats

# tests/plugin_loads.bats
# Validates that the plugin manifest files parse as valid JSON and contain
# the required keys per Claude Code plugin schema.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
}

@test "plugin.json exists" {
  [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]
}

@test "plugin.json parses as valid JSON" {
  run jq '.' "$REPO_ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

@test "plugin.json has name == passthru" {
  run jq -r '.name' "$REPO_ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
  [ "$output" = "passthru" ]
}

@test "plugin.json has semver version" {
  run jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "plugin.json has non-empty description" {
  run jq -r '.description' "$REPO_ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "marketplace.json exists" {
  [ -f "$REPO_ROOT/.claude-plugin/marketplace.json" ]
}

@test "marketplace.json parses as valid JSON" {
  run jq '.' "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
}

@test "marketplace.json has name == passthru" {
  run jq -r '.name' "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  [ "$output" = "passthru" ]
}

@test "marketplace.json has owner.name" {
  run jq -r '.owner.name' "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "marketplace.json has plugins array with one entry" {
  run jq -r '.plugins | length' "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "marketplace.json plugin entry references source ./" {
  run jq -r '.plugins[0].source' "$REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]
  [ "$output" = "./" ]
}

@test "hooks/hooks.json exists" {
  [ -f "$REPO_ROOT/hooks/hooks.json" ]
}

@test "hooks/hooks.json parses as valid JSON" {
  run jq '.' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
}

@test "hooks/hooks.json has exactly one PreToolUse entry" {
  run jq -r '.hooks.PreToolUse | length' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "hooks/hooks.json PreToolUse matcher is *" {
  run jq -r '.hooks.PreToolUse[0].matcher' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "*" ]
}

@test "hooks/hooks.json PreToolUse command uses CLAUDE_PLUGIN_ROOT" {
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  [[ "$output" == *'pre-tool-use.sh' ]]
}

@test "hooks/hooks.json PreToolUse timeout is 10" {
  # 10s leaves headroom for ~50-rule sets where per-rule jq+perl forks add up.
  run jq -r '.hooks.PreToolUse[0].hooks[0].timeout' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "hooks/hooks.json has exactly one PostToolUse entry" {
  run jq -r '.hooks.PostToolUse | length' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "hooks/hooks.json PostToolUse matcher is *" {
  run jq -r '.hooks.PostToolUse[0].matcher' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "*" ]
}

@test "hooks/hooks.json PostToolUse command uses CLAUDE_PLUGIN_ROOT" {
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  [[ "$output" == *'post-tool-use.sh' ]]
}

@test "hooks/hooks.json PostToolUse timeout is 10" {
  run jq -r '.hooks.PostToolUse[0].hooks[0].timeout' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "hooks/hooks.json has exactly one PostToolUseFailure entry" {
  # CC routes failed tool calls (non-zero outcomes, including permission
  # refusals) to PostToolUseFailure rather than PostToolUse. Registering a
  # dedicated handler lets us classify failed passthrough calls instead of
  # leaving orphan breadcrumbs + incomplete audit lines.
  run jq -r '.hooks.PostToolUseFailure | length' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "hooks/hooks.json PostToolUseFailure matcher is *" {
  run jq -r '.hooks.PostToolUseFailure[0].matcher' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "*" ]
}

@test "hooks/hooks.json PostToolUseFailure command uses bash + CLAUDE_PLUGIN_ROOT" {
  run jq -r '.hooks.PostToolUseFailure[0].hooks[0].command' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [[ "$output" == bash\ * ]]
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  [[ "$output" == *'post-tool-use-failure.sh' ]]
}

@test "hooks/hooks.json PostToolUseFailure timeout is 10" {
  # Same budget as PostToolUse since the handler runs the same classifier.
  run jq -r '.hooks.PostToolUseFailure[0].hooks[0].timeout' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

@test "hooks/hooks.json PostToolUseFailure handler script exists and is executable" {
  local script="$REPO_ROOT/hooks/handlers/post-tool-use-failure.sh"
  [ -f "$script" ]
  [ -x "$script" ]
}

@test "hooks/hooks.json has exactly one SessionStart entry" {
  run jq -r '.hooks.SessionStart | length' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "hooks/hooks.json SessionStart command uses bash prefix and CLAUDE_PLUGIN_ROOT" {
  # Matches memsearch's known-working pattern: `bash ${CLAUDE_PLUGIN_ROOT}/...`.
  # The bash prefix avoids executable-bit / shebang edge cases on some hosts.
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [[ "$output" == bash\ * ]]
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
  [[ "$output" == *'session-start.sh' ]]
}

@test "hooks/hooks.json SessionStart timeout is 5" {
  # Short timeout: the handler is a few stat calls + a single jq, no rule load.
  run jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "hooks/hooks.json SessionStart handler script exists and is executable" {
  local script="$REPO_ROOT/hooks/handlers/session-start.sh"
  [ -f "$script" ]
  [ -x "$script" ]
}

@test "README.md exists and is non-empty" {
  [ -f "$REPO_ROOT/README.md" ]
  [ -s "$REPO_ROOT/README.md" ]
}

@test ".gitignore exists and excludes tests/tmp/" {
  [ -f "$REPO_ROOT/.gitignore" ]
  grep -q "tests/tmp/" "$REPO_ROOT/.gitignore"
}

@test ".gitignore excludes .DS_Store" {
  grep -q "\.DS_Store" "$REPO_ROOT/.gitignore"
}
