#!/usr/bin/env bats

# tests/command_frontmatter.bats
# Shared lint test for slash command markdown files under commands/.
# Asserts that each file has a well-formed YAML frontmatter block (delimited
# by --- on its own line at the top of the file, followed by a second --- on
# its own line), and that the frontmatter contains non-empty `description`
# and `argument-hint` keys.
#
# Covers: add.md (Task 6). Future tasks extend this file to cover
# suggest.md, verify.md, and log.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMMANDS_DIR="$REPO_ROOT/commands"
  export REPO_ROOT COMMANDS_DIR
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# extract_frontmatter <file> -> prints frontmatter body (between the two ---
# delimiter lines) to stdout, or returns non-zero if the file does not have a
# valid YAML frontmatter block at the top.
extract_frontmatter() {
  local file="$1"
  [ -f "$file" ] || return 1
  awk '
    NR == 1 {
      if ($0 != "---") { exit 2 }
      in_fm = 1
      next
    }
    in_fm && $0 == "---" {
      exit 0
    }
    in_fm {
      print
    }
  ' "$file"
}

# frontmatter_value <file> <key> -> prints the scalar value for `key` in the
# frontmatter, stripped of surrounding quotes. Returns non-zero on missing.
frontmatter_value() {
  local file="$1"
  local key="$2"
  local fm
  fm="$(extract_frontmatter "$file")" || return 1
  # Match `key:` at column zero, capture the rest of the line.
  local line
  line="$(printf '%s\n' "$fm" | grep -E "^${key}:" | head -n1 || true)"
  [ -n "$line" ] || return 1
  # Strip the key + colon + optional whitespace.
  local val="${line#${key}:}"
  # Trim leading whitespace.
  val="${val#"${val%%[![:space:]]*}"}"
  # Strip surrounding single or double quotes (one layer only).
  case "$val" in
    \"*\") val="${val%\"}"; val="${val#\"}" ;;
    \'*\') val="${val%\'}"; val="${val#\'}" ;;
  esac
  printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# Tests - commands/add.md
# ---------------------------------------------------------------------------

@test "commands/add.md exists" {
  [ -f "$COMMANDS_DIR/add.md" ]
}

@test "commands/add.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}

@test "commands/add.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/add.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/add.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/add.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/add.md body mentions write-rule.sh" {
  run grep -q "write-rule.sh" "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}

@test "commands/add.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}

@test "commands/add.md body mentions --deny flag" {
  run grep -q -- '--deny' "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}

@test "commands/add.md body mentions --field flag" {
  run grep -q -- '--field' "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}

@test "commands/add.md body mentions user and project scope" {
  run grep -q 'user' "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
  run grep -q 'project' "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}
