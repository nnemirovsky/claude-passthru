#!/usr/bin/env bats

# tests/list_script.bats
# End-to-end coverage for scripts/list.sh. Hermetic via PASSTHRU_USER_HOME +
# PASSTHRU_PROJECT_DIR so real ~/.claude is never touched. Each test builds a
# fresh fixture set with known rules spanning all four files (user/project x
# authored/imported) and verifies filtering, grouping, and output formats.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIST_SCRIPT="$REPO_ROOT/scripts/list.sh"

  TMP="$(mktemp -d -t passthru-list.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"

  # Force "not a tty" so ANSI color codes never leak into captured output.
  export TERM=dumb
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

run_list() {
  run bash "$LIST_SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# Fixture builder: writes known rules to each of the four scope files.
# ---------------------------------------------------------------------------

write_fixture() {
  # User authored: 2 allow + 1 deny.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "Bash", "match": {"command": "^gh api /repos/"}, "reason": "github repo api"},
    {"tool": "^mcp__gemini-", "reason": "all gemini mcp"}
  ],
  "deny": [
    {"tool": "Bash", "match": {"command": "rm\\s+-rf\\s+/"}, "reason": "safety"}
  ]
}
EOF

  # User imported: 1 allow.
  cat > "$USER_ROOT/.claude/passthru.imported.json" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "Bash", "match": {"command": "^ls(\\s|$)"}}
  ],
  "deny": []
}
EOF

  # Project authored: 1 allow.
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "Read", "match": {"file_path": "^/tmp/"}, "reason": "project reads"}
  ],
  "deny": []
}
EOF

  # Project imported: 1 deny.
  cat > "$PROJ_ROOT/.claude/passthru.imported.json" <<'EOF'
{
  "version": 1,
  "allow": [],
  "deny": [
    {"tool": "Bash", "match": {"command": "^sudo\\s"}, "reason": "no sudo"}
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# Default output
# ---------------------------------------------------------------------------

@test "list: default output includes all rules across all files" {
  write_fixture
  run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER / allow (authored"* ]]
  [[ "$output" == *"USER / deny (authored"* ]]
  [[ "$output" == *"USER / allow (imported"* ]]
  [[ "$output" == *"PROJECT / allow (authored"* ]]
  [[ "$output" == *"PROJECT / deny (imported"* ]]
  # Reasons visible.
  [[ "$output" == *"github repo api"* ]]
  [[ "$output" == *"all gemini mcp"* ]]
  [[ "$output" == *"safety"* ]]
  [[ "$output" == *"project reads"* ]]
  [[ "$output" == *"no sudo"* ]]
}

@test "list: default output uses 1-based indexing within each source group" {
  write_fixture
  run_list
  [ "$status" -eq 0 ]
  # User authored allow has two rules; first "1  Bash" then "2  ^mcp__gemini-".
  # Column alignment is fixed width, assert on the presence of both lines.
  [[ "$output" == *"1  Bash"* ]]
  [[ "$output" == *"2  ^mcp__gemini-"* ]]
  # Deny list resets to index 1.
  [[ "$output" == *"1  Bash              "* ]] || [[ "$output" == *"1  Bash "* ]]
}

# ---------------------------------------------------------------------------
# --scope filter
# ---------------------------------------------------------------------------

@test "list: --scope user shows only user scope" {
  write_fixture
  run_list --scope user
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER /"* ]]
  [[ "$output" != *"PROJECT /"* ]]
  # Project-only rules must be absent.
  [[ "$output" != *"project reads"* ]]
  [[ "$output" != *"no sudo"* ]]
}

@test "list: --scope project shows only project scope" {
  write_fixture
  run_list --scope project
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROJECT /"* ]]
  [[ "$output" != *"USER /"* ]]
  # User-only rules must be absent.
  [[ "$output" != *"github repo api"* ]]
  [[ "$output" != *"all gemini mcp"* ]]
}

# ---------------------------------------------------------------------------
# --list filter
# ---------------------------------------------------------------------------

@test "list: --list deny filters to deny groups only" {
  write_fixture
  run_list --list deny
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER / deny"* ]]
  [[ "$output" == *"PROJECT / deny"* ]]
  [[ "$output" != *"USER / allow"* ]]
  [[ "$output" != *"PROJECT / allow"* ]]
  # Allow-side reasons must not appear.
  [[ "$output" != *"github repo api"* ]]
  # Deny-side reasons visible.
  [[ "$output" == *"safety"* ]]
  [[ "$output" == *"no sudo"* ]]
}

@test "list: --list allow filters to allow groups only" {
  write_fixture
  run_list --list allow
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow"* ]]
  [[ "$output" != *"deny"* ]]
  [[ "$output" != *"safety"* ]]
}

# ---------------------------------------------------------------------------
# --tool filter
# ---------------------------------------------------------------------------

@test "list: --tool Bash filters to Bash rules only" {
  write_fixture
  run_list --tool Bash
  [ "$status" -eq 0 ]
  # Bash rules visible (gh api, rm -rf, ls, sudo).
  [[ "$output" == *"github repo api"* ]]
  [[ "$output" == *"safety"* ]]
  [[ "$output" == *"no sudo"* ]]
  # Non-Bash tools filtered out.
  [[ "$output" != *"all gemini mcp"* ]]
  [[ "$output" != *"project reads"* ]]
}

@test "list: --tool with bad regex exits 2" {
  write_fixture
  run_list --tool '(unclosed'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --tool"* ]]
}

# ---------------------------------------------------------------------------
# --source filter
# ---------------------------------------------------------------------------

@test "list: --source imported shows only imported rules" {
  write_fixture
  run_list --source imported
  [ "$status" -eq 0 ]
  [[ "$output" == *"imported"* ]]
  [[ "$output" != *"authored"* ]]
  # Imported rules visible.
  [[ "$output" == *"no sudo"* ]]
  # Authored-only rules absent.
  [[ "$output" != *"github repo api"* ]]
  [[ "$output" != *"project reads"* ]]
}

@test "list: --source authored shows only authored rules" {
  write_fixture
  run_list --source authored
  [ "$status" -eq 0 ]
  [[ "$output" == *"authored"* ]]
  [[ "$output" != *"imported"* ]]
  # Imported rules absent.
  [[ "$output" != *"no sudo"* ]]
  [[ "$output" != *"^ls(\\s|$)"* ]]
}

# ---------------------------------------------------------------------------
# --flat
# ---------------------------------------------------------------------------

@test "list: --flat emits a single flat table with scope/list/source columns" {
  write_fixture
  run_list --flat
  [ "$status" -eq 0 ]
  # Header row has the flat columns.
  [[ "$output" == *"scope"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"source"* ]]
  [[ "$output" == *"tool"* ]]
  [[ "$output" == *"match-summary"* ]]
  [[ "$output" == *"reason"* ]]
  # Flat table rows begin with scope names on the left (no "USER / allow ..." header).
  # We should see multiple rows starting with "user " and "project ".
  printf '%s\n' "$output" | grep -qE '^user[[:space:]]+allow[[:space:]]+authored'
  printf '%s\n' "$output" | grep -qE '^project[[:space:]]+allow[[:space:]]+authored'
  # Grouped-format header must NOT be present.
  [[ "$output" != *"USER / allow (authored"* ]]
}

# ---------------------------------------------------------------------------
# --format json
# ---------------------------------------------------------------------------

@test "list: --format json emits a valid JSON array of annotated rule objects" {
  write_fixture
  run_list --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
  # 6 rules in the fixture total (2 user-auth-allow, 1 user-auth-deny,
  # 1 user-imp-allow, 1 proj-auth-allow, 1 proj-imp-deny).
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" -eq 6 ]
  # Each entry has the expected annotation fields.
  printf '%s' "$output" | jq -e 'all(has("scope") and has("list") and has("source") and has("index") and has("rule") and has("path"))' >/dev/null
}

@test "list: --format json respects --scope filter" {
  write_fixture
  run_list --format json --scope user
  [ "$status" -eq 0 ]
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" -eq 4 ]
  # All entries must have scope=user.
  printf '%s' "$output" | jq -e 'all(.scope == "user")' >/dev/null
}

# ---------------------------------------------------------------------------
# --format raw
# ---------------------------------------------------------------------------

@test "list: --format raw emits only original rule JSON (no annotations)" {
  write_fixture
  run_list --format raw
  [ "$status" -eq 0 ]
  # Each line is a standalone JSON object (6 rules total in fixture).
  local n
  n="$(printf '%s\n' "$output" | grep -c '^{' || true)"
  [ "$n" -eq 6 ]
  # No annotation fields leak into raw output.
  [[ "$output" != *'"scope"'* ]]
  [[ "$output" != *'"source"'* ]]
  [[ "$output" != *'"index"'* ]]
  [[ "$output" != *'"path"'* ]]
  # But actual rule fields are present.
  [[ "$output" == *'"tool":"Bash"'* ]]
  [[ "$output" == *'"reason":"github repo api"'* ]]
}

# ---------------------------------------------------------------------------
# Empty / missing
# ---------------------------------------------------------------------------

@test "list: no rule files -> 'no rules found' on stderr, exit 0" {
  run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no rules found"* ]]
}

@test "list: all files empty -> 'no rules found' on stderr, exit 0" {
  # Write skeleton files with empty allow/deny.
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$USER_ROOT/.claude/passthru.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$PROJ_ROOT/.claude/passthru.json"
  run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no rules found"* ]]
}

@test "list: filter matches zero rules -> 'no rules found' on stderr, exit 0" {
  write_fixture
  run_list --tool '^never-matching-tool$'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no rules found"* ]]
}

# ---------------------------------------------------------------------------
# Flags / usage
# ---------------------------------------------------------------------------

@test "list: --help exits 0 and prints usage" {
  run_list --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: list.sh"* ]]
  [[ "$output" == *"--scope"* ]]
  [[ "$output" == *"--list"* ]]
  [[ "$output" == *"--source"* ]]
  [[ "$output" == *"--format"* ]]
  [[ "$output" == *"--flat"* ]]
}

@test "list: unknown flag exits 2" {
  run_list --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "list: invalid --format exits 2" {
  run_list --format bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --format"* ]]
}

@test "list: invalid --scope exits 2" {
  run_list --scope global
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --scope"* ]]
}

@test "list: invalid --list exits 2" {
  run_list --list warn
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --list"* ]]
}

@test "list: invalid --source exits 2" {
  run_list --source manual
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --source"* ]]
}

# ---------------------------------------------------------------------------
# Match-summary and truncation
# ---------------------------------------------------------------------------

@test "list: rule without a match block shows '-' in match-summary" {
  # Fixture with an MCP-namespace-only rule (no match block).
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    {"tool": "^mcp__server__", "reason": "whole mcp"}
  ],
  "deny": []
}
EOF
  run_list
  [ "$status" -eq 0 ]
  # The match-summary column for this row must be "-".
  [[ "$output" == *" -"* ]] || [[ "$output" == *"- "* ]]
  [[ "$output" == *"whole mcp"* ]]
}

@test "list: long match value is printed in full, wrapped across multiple lines, never truncated" {
  # Fixture with a very long match value.
  local longcmd
  longcmd="^this_is_a_very_long_regex_pattern_that_should_exceed_the_fifty_character_truncation_boundary_by_a_clear_margin"
  jq -n --arg lc "$longcmd" '{
    version: 1,
    allow: [{ tool: "Bash", match: { command: $lc }, reason: "too long" }],
    deny: []
  }' > "$USER_ROOT/.claude/passthru.json"
  # Fix width so wrapping is deterministic.
  COLUMNS=120 run_list
  [ "$status" -eq 0 ]
  # No ellipsis anywhere in the table output. Truncation is gone.
  [[ "$output" != *"..."* ]]
  # Start of the regex appears on the first wrapped line.
  [[ "$output" == *"this_is_a_very_long_regex_pattern"* ]]
  # The tail of the regex that the old truncation used to drop is now
  # present verbatim on a continuation line.
  [[ "$output" == *"boundary_by_a_clear_margin"* ]]
  # Output should span multiple lines for this row (i.e. at least one
  # continuation line exists).
  local n_lines
  n_lines="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  [ "$n_lines" -ge 4 ]  # header + column row + >= 2 wrapped lines
}

@test "list: continuation lines pad the # and tool columns with spaces (column alignment)" {
  # A row whose match-summary wraps yields continuation lines whose leading
  # characters (covering #, tool columns) are all spaces.
  local longcmd
  longcmd="^pattern_one|^pattern_two|^pattern_three|^pattern_four|^pattern_five|^pattern_six|^pattern_seven"
  jq -n --arg lc "$longcmd" '{
    version: 1,
    allow: [{ tool: "Bash", match: { command: $lc }, reason: "wrap" }],
    deny: []
  }' > "$USER_ROOT/.claude/passthru.json"
  COLUMNS=100 run_list
  [ "$status" -eq 0 ]
  # Find a line that starts with "   1  Bash" (first line of the wrapped row).
  local first_line
  first_line="$(printf '%s\n' "$output" | grep -n -E '^   1  Bash' | head -1 | cut -d: -f1)"
  [ -n "$first_line" ]
  # The next line should be a continuation: begins with whitespace only for
  # the # + tool columns (no digit, no tool name). It should also contain
  # another fragment of the pattern text.
  local next_line
  next_line="$(printf '%s\n' "$output" | sed -n "$((first_line + 1))p")"
  [ -n "$next_line" ]
  # First 18+ characters (# + padding + tool padding) must be spaces.
  [[ "$next_line" =~ ^[[:space:]]{10,}[^[:space:]] ]]
  # It must NOT begin with "   2  " (another row index).
  [[ ! "$next_line" =~ ^\ +[0-9]+\ +[A-Za-z] ]]
}

@test "list: --flat continuation lines pad scope/list/source/#/tool columns" {
  # Same long pattern, but with the flat renderer. Continuation lines should
  # leave the leading scope/list/source/#/tool columns blank.
  local longcmd
  longcmd="^pattern_alpha|^pattern_beta|^pattern_gamma|^pattern_delta|^pattern_epsilon|^pattern_zeta|^pattern_eta"
  jq -n --arg lc "$longcmd" '{
    version: 1,
    allow: [{ tool: "Bash", match: { command: $lc }, reason: "wrap" }],
    deny: []
  }' > "$USER_ROOT/.claude/passthru.json"
  COLUMNS=120 run_list --flat
  [ "$status" -eq 0 ]
  # The first data row begins with "user " on column 0.
  local first_line
  first_line="$(printf '%s\n' "$output" | grep -n -E '^user[[:space:]]+allow' | head -1 | cut -d: -f1)"
  [ -n "$first_line" ]
  # Next line: continuation must start with whitespace (no "user", no "allow").
  local next_line
  next_line="$(printf '%s\n' "$output" | sed -n "$((first_line + 1))p")"
  [ -n "$next_line" ]
  [[ "$next_line" =~ ^[[:space:]]{20,} ]]
  [[ ! "$next_line" == user* ]]
  [[ ! "$next_line" == project* ]]
}

@test "list: extremely narrow terminal still prints full regex, never drops chars" {
  local longcmd
  longcmd="^abcdefghijklmnopqrstuvwxyz0123456789_abcdefghijklmnopqrstuvwxyz"
  jq -n --arg lc "$longcmd" '{
    version: 1,
    allow: [{ tool: "Bash", match: { command: $lc }, reason: "narrow" }],
    deny: []
  }' > "$USER_ROOT/.claude/passthru.json"
  COLUMNS=40 run_list
  [ "$status" -eq 0 ]
  # The tail of the regex (what the old truncation used to drop) is
  # present somewhere in the wrapped output.
  [[ "$output" == *"nopqrstuvwxyz"* ]]
  # The opening anchor of the regex is present at the start of the row.
  [[ "$output" == *"^abcdefghijkl"* ]]
  # No truncation indicator leaked into output.
  [[ "$output" != *"..."* ]]
}

# ---------------------------------------------------------------------------
# ANSI color (tty only)
# ---------------------------------------------------------------------------

@test "list: no ANSI escape sequences when TERM=dumb" {
  write_fixture
  TERM=dumb run_list
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]]
}

# ---------------------------------------------------------------------------
# Interaction with remove: indexes match
# ---------------------------------------------------------------------------

@test "list: --format json index matches the rule's position (1-based) within authored allow" {
  write_fixture
  run_list --format json --scope user --list allow --source authored
  [ "$status" -eq 0 ]
  # User authored allow has two rules: gh api (index 1), mcp__gemini- (index 2).
  local first second
  first="$(printf '%s' "$output" | jq -r '.[0].index')"
  second="$(printf '%s' "$output" | jq -r '.[1].index')"
  [ "$first" = "1" ]
  [ "$second" = "2" ]
  # Sanity: tools match the expected order.
  local first_tool second_tool
  first_tool="$(printf '%s' "$output" | jq -r '.[0].rule.tool')"
  second_tool="$(printf '%s' "$output" | jq -r '.[1].rule.tool')"
  [ "$first_tool" = "Bash" ]
  [ "$second_tool" = "^mcp__gemini-" ]
}

# ---------------------------------------------------------------------------
# Malformed JSON handling: a parse-failing file is treated as empty, not fatal.
# Matches load_rules' behavior so list.sh stays useful even when bootstrap
# hasn't run yet or the authored file is being edited.
# ---------------------------------------------------------------------------

@test "list: malformed file silently treated as empty; other files still listed" {
  write_fixture
  # Corrupt the user-authored file.
  printf '{not valid json' > "$USER_ROOT/.claude/passthru.json"
  run_list
  [ "$status" -eq 0 ]
  # User authored rules (now unreadable) must be absent from output.
  [[ "$output" != *"github repo api"* ]]
  # Other files still produce output.
  [[ "$output" == *"no sudo"* ]]
  [[ "$output" == *"project reads"* ]]
}

# ---------------------------------------------------------------------------
# ask[] support (schema v2)
# ---------------------------------------------------------------------------

write_fixture_with_ask() {
  # User authored: 1 allow + 1 ask + 1 deny (schema v2).
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    {"tool": "Bash", "match": {"command": "^gh api /repos/"}, "reason": "github repo api"}
  ],
  "ask": [
    {"tool": "WebFetch", "match": {"url": "^https?://unsafe\\."}, "reason": "prompt on unsafe"}
  ],
  "deny": [
    {"tool": "Bash", "match": {"command": "rm\\s+-rf\\s+/"}, "reason": "safety"}
  ]
}
EOF
}

@test "list: default output renders an ASK group when ask[] has rules" {
  write_fixture_with_ask
  run_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER / ask (authored"* ]]
  [[ "$output" == *"prompt on unsafe"* ]]
  # Allow and deny groups still rendered.
  [[ "$output" == *"USER / allow (authored"* ]]
  [[ "$output" == *"USER / deny (authored"* ]]
}

@test "list: --list ask filters to ask-only output" {
  write_fixture_with_ask
  run_list --list ask
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER / ask (authored"* ]]
  [[ "$output" == *"prompt on unsafe"* ]]
  # Allow and deny groups must be absent.
  [[ "$output" != *"USER / allow"* ]]
  [[ "$output" != *"USER / deny"* ]]
  [[ "$output" != *"github repo api"* ]]
  [[ "$output" != *"safety"* ]]
}

@test "list: --list all includes the ask group alongside allow and deny" {
  write_fixture_with_ask
  run_list --list all
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER / allow (authored"* ]]
  [[ "$output" == *"USER / ask (authored"* ]]
  [[ "$output" == *"USER / deny (authored"* ]]
  # Reasons from every list visible.
  [[ "$output" == *"github repo api"* ]]
  [[ "$output" == *"prompt on unsafe"* ]]
  [[ "$output" == *"safety"* ]]
}

@test "list: --list ask on file with no ask[] -> 'no rules found', exit 0" {
  # A v1 fixture with no ask[] array at all.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [{"tool": "Bash", "match": {"command": "^ls"}}],
  "deny": []
}
EOF
  run_list --list ask
  [ "$status" -eq 0 ]
  [[ "$output" == *"no rules found"* ]]
}

@test "list: grouped ASK header uses a distinct ANSI color from ALLOW and DENY" {
  # Assert the three list colors are distinct. Don't rely on tty detection
  # (bats captures stdout, so -t 1 is false inside run). Instead, extract
  # the color_for_list function block from list.sh and eval it in a subshell
  # so we can compare the actual emitted bytes. The isolated-color assertion
  # avoids pinning to specific ANSI codes so future color tweaks don't break
  # the test as long as the three values remain distinct.
  local fn_src
  fn_src="$(awk '/^color_for_list\(\)/{f=1} f{print} f && /^}$/{exit}' "$LIST_SCRIPT")"
  [ -n "$fn_src" ]
  local allow_code deny_code ask_code
  allow_code="$(bash -c "$fn_src; color_for_list allow" | od -An -c | tr -d ' \n')"
  deny_code="$(bash -c "$fn_src; color_for_list deny"  | od -An -c | tr -d ' \n')"
  ask_code="$(bash -c "$fn_src; color_for_list ask"    | od -An -c | tr -d ' \n')"
  [ -n "$allow_code" ]
  [ -n "$deny_code" ]
  [ -n "$ask_code" ]
  # All three must differ pairwise.
  [ "$ask_code" != "$allow_code" ]
  [ "$ask_code" != "$deny_code" ]
  [ "$allow_code" != "$deny_code" ]
}

@test "list: --flat mode renders 'ask' in the list column for ask rules" {
  write_fixture_with_ask
  run_list --flat
  [ "$status" -eq 0 ]
  # A data row should begin with "user" then "ask" in the list column.
  # Column spacing is deterministic: %-8s %-6s %-9s ...
  printf '%s\n' "$output" | grep -qE '^user[[:space:]]+ask[[:space:]]+authored'
  # Allow and deny rows also present.
  printf '%s\n' "$output" | grep -qE '^user[[:space:]]+allow[[:space:]]+authored'
  printf '%s\n' "$output" | grep -qE '^user[[:space:]]+deny[[:space:]]+authored'
}

@test "list: --format json includes ask entries when --list ask" {
  write_fixture_with_ask
  run_list --format json --list ask
  [ "$status" -eq 0 ]
  # Exactly one ask rule in the fixture.
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" -eq 1 ]
  # The single entry has list=ask.
  printf '%s' "$output" | jq -e '.[0].list == "ask"' >/dev/null
  # Its rule carries the expected tool.
  printf '%s' "$output" | jq -e '.[0].rule.tool == "WebFetch"' >/dev/null
}

@test "list: --format json --list all surfaces ask alongside allow and deny" {
  write_fixture_with_ask
  run_list --format json --list all
  [ "$status" -eq 0 ]
  # 3 rules total: 1 allow, 1 ask, 1 deny.
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" -eq 3 ]
  # All three list values appear exactly once.
  printf '%s' "$output" | jq -e '[.[].list] | sort == ["allow","ask","deny"]' >/dev/null
}

@test "list: invalid --list 'ask' spelled wrong still exits 2" {
  # Sanity: the allowed values remain a closed set.
  run_list --list aks
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --list"* ]]
}
