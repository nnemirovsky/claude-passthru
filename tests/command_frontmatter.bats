#!/usr/bin/env bats

# tests/command_frontmatter.bats
# Shared lint test for slash command markdown files under commands/.
# Asserts that each file has a well-formed YAML frontmatter block (delimited
# by --- on its own line at the top of the file, followed by a second --- on
# its own line), and that the frontmatter contains non-empty `description`
# and `argument-hint` keys.
#
# Covers: add.md (Task 6), suggest.md (Task 7), verify.md (Task 8),
# log.md (Task 8b).

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

@test "commands/add.md frontmatter argument-hint mentions --ask flag" {
  # Task 4: --ask is documented alongside --deny in the argument-hint so
  # auto-completion and help surface the third list target.
  run frontmatter_value "$COMMANDS_DIR/add.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--ask"* ]]
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

@test "commands/add.md body mentions --ask flag" {
  # Task 4: the body explains --ask as routing to the ask[] list.
  run grep -q -- '--ask' "$COMMANDS_DIR/add.md"
  [ "$status" -eq 0 ]
}

@test "commands/add.md body includes the worked --ask example" {
  # Task 4: a runnable example that documents the canonical --ask form.
  run grep -q 'passthru:add --ask' "$COMMANDS_DIR/add.md"
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

@test "commands/suggest.md body mentions ask as a third option" {
  # Task 5: after regex confirmation, suggest offers allow/ask/deny.
  # The body must mention ask alongside allow and deny so the
  # write-rule.sh invocation supports routing to the ask list.
  run grep -qi 'ask' "$COMMANDS_DIR/suggest.md"
  [ "$status" -eq 0 ]
}

@test "commands/suggest.md body mentions the three-way list target in write-rule.sh" {
  # The write-rule.sh invocation line must advertise allow|ask|deny as the
  # list options so Claude picks the right one at runtime.
  run grep -qE 'allow\|ask\|deny|allow.*ask.*deny' "$COMMANDS_DIR/suggest.md"
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
# Tests - commands/log.md
# ---------------------------------------------------------------------------

@test "commands/log.md exists" {
  [ -f "$COMMANDS_DIR/log.md" ]
}

@test "commands/log.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
}

@test "commands/log.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/log.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/log.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/log.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/log.md frontmatter argument-hint mentions key flags" {
  run frontmatter_value "$COMMANDS_DIR/log.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--since"* ]]
  [[ "$output" == *"--event"* ]]
  [[ "$output" == *"--tool"* ]]
  [[ "$output" == *"--tail"* ]]
  [[ "$output" == *"--format"* ]]
  [[ "$output" == *"--enable"* ]]
  [[ "$output" == *"--disable"* ]]
  [[ "$output" == *"--status"* ]]
}

@test "commands/log.md body mentions log.sh" {
  run grep -q "log.sh" "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
}

@test "commands/log.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
}

@test "commands/log.md body mentions \$ARGUMENTS pass-through" {
  run grep -q 'ARGUMENTS' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
}

@test "commands/log.md body mentions audit sentinel" {
  run grep -q 'passthru.audit.enabled' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
}

@test "commands/log.md body mentions key event categories" {
  run grep -q 'allow' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
  run grep -q 'deny' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
  run grep -q 'passthrough' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
  run grep -q 'asked_' "$COMMANDS_DIR/log.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Tests - commands/bootstrap.md
# ---------------------------------------------------------------------------

@test "commands/bootstrap.md exists" {
  [ -f "$COMMANDS_DIR/bootstrap.md" ]
}

@test "commands/bootstrap.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/bootstrap.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/bootstrap.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/bootstrap.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/bootstrap.md frontmatter argument-hint mentions scope flags" {
  run frontmatter_value "$COMMANDS_DIR/bootstrap.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--user-only"* ]]
  [[ "$output" == *"--project-only"* ]]
}

@test "commands/bootstrap.md body mentions bootstrap.sh" {
  run grep -q "bootstrap.sh" "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md body mentions verify.sh" {
  run grep -q "verify.sh" "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md body mentions --write flag" {
  run grep -q -- '--write' "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md body mentions \$ARGUMENTS pass-through" {
  run grep -q 'ARGUMENTS' "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md body mentions passthru.imported.json target" {
  run grep -q 'passthru.imported.json' "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

@test "commands/bootstrap.md body mentions confirmation step" {
  run grep -qi 'confirm' "$COMMANDS_DIR/bootstrap.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Tests - commands/list.md
# ---------------------------------------------------------------------------

@test "commands/list.md exists" {
  [ -f "$COMMANDS_DIR/list.md" ]
}

@test "commands/list.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/list.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/list.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/list.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/list.md frontmatter argument-hint mentions key flags" {
  run frontmatter_value "$COMMANDS_DIR/list.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--scope"* ]]
  [[ "$output" == *"--list"* ]]
  [[ "$output" == *"--source"* ]]
  [[ "$output" == *"--format"* ]]
  [[ "$output" == *"--flat"* ]]
  [[ "$output" == *"--tool"* ]]
}

@test "commands/list.md frontmatter argument-hint mentions ask as a --list value" {
  # Task 5: ask is documented alongside allow/deny in the --list argument
  # so shell completion and help text surface the third list target.
  run frontmatter_value "$COMMANDS_DIR/list.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ask"* ]]
}

@test "commands/list.md body mentions the ask filter" {
  # Task 5: the body explains ask as a --list filter value.
  run grep -q 'ask' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md body includes a --list ask example" {
  run grep -q 'passthru:list --list ask' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md body mentions list.sh" {
  run grep -q "list.sh" "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md body mentions \$ARGUMENTS pass-through" {
  run grep -q 'ARGUMENTS' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md body mentions scope and source concepts" {
  run grep -q 'authored' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
  run grep -q 'imported' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

@test "commands/list.md body points at /passthru:remove" {
  run grep -q '/passthru:remove' "$COMMANDS_DIR/list.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Tests - commands/remove.md
# ---------------------------------------------------------------------------

@test "commands/remove.md exists" {
  [ -f "$COMMANDS_DIR/remove.md" ]
}

@test "commands/remove.md has frontmatter delimiters" {
  run extract_frontmatter "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md frontmatter has non-empty description" {
  run frontmatter_value "$COMMANDS_DIR/remove.md" "description"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/remove.md frontmatter has non-empty argument-hint" {
  run frontmatter_value "$COMMANDS_DIR/remove.md" "argument-hint"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commands/remove.md frontmatter argument-hint mentions the three positional slots" {
  run frontmatter_value "$COMMANDS_DIR/remove.md" "argument-hint"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scope"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"index"* ]]
}

@test "commands/remove.md body mentions ask as a valid list value" {
  # Task 5: remove accepts ask as a list argument alongside allow/deny.
  run grep -q 'ask' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body includes a worked ask example" {
  run grep -q 'passthru:remove user ask' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body mentions remove-rule.sh" {
  run grep -q "remove-rule.sh" "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body mentions CLAUDE_PLUGIN_ROOT" {
  run grep -q 'CLAUDE_PLUGIN_ROOT' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body mentions \$ARGUMENTS hint" {
  run grep -q 'ARGUMENTS' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body points at /passthru:list" {
  run grep -q '/passthru:list' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body mentions imported-rule refusal path" {
  run grep -qi 'imported' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
  run grep -q 'bootstrap' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

@test "commands/remove.md body mentions all three exit codes" {
  run grep -q 'Exit 0' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
  run grep -q 'Exit 1' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
  run grep -q 'Exit 2' "$COMMANDS_DIR/remove.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Auto-iteration: every commands/*.md must have a well-formed frontmatter
# block with non-empty description and argument-hint. Picks up new files
# automatically so future command additions get baseline coverage.
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
