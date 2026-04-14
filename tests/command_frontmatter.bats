#!/usr/bin/env bats

# tests/command_frontmatter.bats
# Shared lint test for slash command markdown files under commands/.
# Asserts that each file has a well-formed YAML frontmatter block (delimited
# by --- on its own line at the top of the file, followed by a second --- on
# its own line), and that the frontmatter contains non-empty `description`
# and `argument-hint` keys.
#
# Covers: add.md (Task 6), suggest.md (Task 7), verify.md (Task 8). Future
# tasks extend this file to cover log.md.

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

# ---------------------------------------------------------------------------
# Tests - commands/suggest.md
# ---------------------------------------------------------------------------

@test "commands/suggest.md exists" {
  [ -f "$COMMANDS_DIR/suggest.md" ]
}

@test "commands/suggest.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/suggest.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/suggest.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/suggest.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/suggest.md body mentions write-rule.sh" {
  run grep -q "write-rule.sh" "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md body mentions user and project scope" {
  run grep -q 'user' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
  run grep -q 'project' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md body mentions allow and deny" {
  run grep -q 'allow' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
  run grep -q 'deny' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md body mentions \$ARGUMENTS hint" {
  run grep -q 'ARGUMENTS' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md body mentions narrow vs permissive tradeoff" {
  run grep -qi 'narrow' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
  run grep -qi 'permissive' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Tests - commands/verify.md
# ---------------------------------------------------------------------------

@test "commands/verify.md exists" {
  [ -f "$COMMANDS_DIR/verify.md" ]
}

@test "commands/verify.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

@test "commands/verify.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/verify.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/verify.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/verify.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/verify.md frontmatter argument-hint mentions --scope and --strict" {
  run frontmatter_value "$COMMANDS_DIR/verify.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--scope"* ]]
  [[ "$output" == *"--strict"* ]]
}

@test "commands/verify.md body mentions verify.sh" {
  run grep -q "verify.sh" "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

@test "commands/verify.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

@test "commands/verify.md body mentions \$ARGUMENTS pass-through" {
  run grep -q 'ARGUMENTS' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

@test "commands/verify.md body mentions all three exit codes" {
  run grep -q 'Exit 0' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
  run grep -q 'Exit 1' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
  run grep -q 'Exit 2' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

@test "commands/verify.md body mentions key error categories" {
  run grep -q 'parse:' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
  run grep -q 'regex:' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
  run grep -q 'conflict:' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

@test "commands/verify.md body includes guidance to re-run after editing passthru.json" {
  run grep -q 'passthru.json' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
  run grep -q '/passthru:verify' "$COMMANDS_DIR/verify.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Auto-iteration: every commands/*.md must have a well-formed frontmatter
# block with non-empty description and argument-hint. Picks up new files
# automatically so future tasks (e.g., log.md) get baseline coverage even
# before explicit per-file tests are added.
# ---------------------------------------------------------------------------

@test "every commands/*.md has frontmatter with description and argument-hint" {
  shopt -s nullglob
  local found=0
  for f in "$COMMANDS_DIR"/*.md; do
    found=1
    run extract_frontmatter "$f"
    [ "$status" -eq 0 ] || { echo "missing frontmatter delimiters in $f"; return 1; }
    run frontmatter_value "$f" "description"
    [ "$status" -eq 0 ] || { echo "missing description in $f"; return 1; }
    [ -n "$output" ] || { echo "empty description in $f"; return 1; }
    run frontmatter_value "$f" "argument-hint"
    [ "$status" -eq 0 ] || { echo "missing argument-hint in $f"; return 1; }
    [ -n "$output" ] || { echo "empty argument-hint in $f"; return 1; }
  done
  [ "$found" -eq 1 ]
}
