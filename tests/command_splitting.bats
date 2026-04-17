#!/usr/bin/env bats

# tests/command_splitting.bats
# Validates hooks/common.sh split_bash_command function:
#   - single commands (no split)
#   - pipe splitting
#   - && and || splitting
#   - ; and & splitting
#   - quoted string preservation (single, double, $(), backtick)
#   - redirection stripping
#   - mixed compound commands
#   - parse failure fallback (returns original as single segment)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # Synthetic scope roots so sourcing common.sh path helpers can't touch real ~/.claude.
  TMP="$(mktemp -d -t passthru-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"
  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"

  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Helper: collect NUL-separated output into a bash array.
# Usage: collect_segments <command_string>
# After call, SEGMENTS array holds the segments, SEGMENT_COUNT the count.
collect_segments() {
  SEGMENTS=()
  SEGMENT_COUNT=0
  local seg
  while IFS= read -r -d '' seg; do
    SEGMENTS+=("$seg")
    SEGMENT_COUNT=$((SEGMENT_COUNT + 1))
  done < <(split_bash_command "$1")
}

# ---------------------------------------------------------------------------
# Single commands (no split needed, returns 1 segment)
# ---------------------------------------------------------------------------

@test "split: single command returns 1 segment" {
  collect_segments "ls -la"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "ls -la" ]
}

@test "split: bare command returns 1 segment" {
  collect_segments "ls"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "ls" ]
}

@test "split: complex single command preserves arguments" {
  collect_segments "grep -r 'pattern' /some/path"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "grep -r 'pattern' /some/path" ]
}

# ---------------------------------------------------------------------------
# Pipe splitting: ls | head -> ["ls", "head"]
# ---------------------------------------------------------------------------

@test "split: pipe splits into two segments" {
  collect_segments "ls | head"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "ls" ]
  [ "${SEGMENTS[1]}" = "head" ]
}

@test "split: multi-pipe splits correctly" {
  collect_segments "cat file | grep foo | wc -l"
  [ "$SEGMENT_COUNT" -eq 3 ]
  [ "${SEGMENTS[0]}" = "cat file" ]
  [ "${SEGMENTS[1]}" = "grep foo" ]
  [ "${SEGMENTS[2]}" = "wc -l" ]
}

# ---------------------------------------------------------------------------
# && and || splitting
# ---------------------------------------------------------------------------

@test "split: && splits into segments" {
  collect_segments "mkdir -p dir && cd dir"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "mkdir -p dir" ]
  [ "${SEGMENTS[1]}" = "cd dir" ]
}

@test "split: || splits into segments" {
  collect_segments "test -f file || echo missing"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "test -f file" ]
  [ "${SEGMENTS[1]}" = "echo missing" ]
}

@test "split: mixed && and || splits all" {
  collect_segments "cmd1 && cmd2 || cmd3"
  [ "$SEGMENT_COUNT" -eq 3 ]
  [ "${SEGMENTS[0]}" = "cmd1" ]
  [ "${SEGMENTS[1]}" = "cmd2" ]
  [ "${SEGMENTS[2]}" = "cmd3" ]
}

# ---------------------------------------------------------------------------
# ; and & splitting
# ---------------------------------------------------------------------------

@test "split: semicolon splits into segments" {
  collect_segments "echo hello; echo world"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "echo hello" ]
  [ "${SEGMENTS[1]}" = "echo world" ]
}

@test "split: background & splits into segments" {
  collect_segments "sleep 10 & echo foreground"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "sleep 10" ]
  [ "${SEGMENTS[1]}" = "echo foreground" ]
}

# ---------------------------------------------------------------------------
# Quoted strings preserved (operators inside quotes are NOT split points)
# ---------------------------------------------------------------------------

@test "split: single-quoted string preserved" {
  collect_segments "echo 'foo && bar'"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "echo 'foo && bar'" ]
}

@test "split: single-quoted pipe preserved" {
  collect_segments "echo 'foo | bar'"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "echo 'foo | bar'" ]
}

@test "split: double-quoted string preserved" {
  collect_segments 'echo "foo | bar"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "foo | bar"' ]
}

@test "split: double-quoted && preserved" {
  collect_segments 'echo "foo && bar"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "foo && bar"' ]
}

# ---------------------------------------------------------------------------
# $() subshell preserved
# ---------------------------------------------------------------------------

@test "split: dollar-paren subshell preserved" {
  collect_segments 'echo $(foo | bar)'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo $(foo | bar)' ]
}

@test "split: nested dollar-paren subshell preserved" {
  collect_segments 'echo $(cat $(find . -name "*.txt"))'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo $(cat $(find . -name "*.txt"))' ]
}

@test "split: dollar-paren with && inside preserved" {
  collect_segments 'result=$(cmd1 && cmd2)'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'result=$(cmd1 && cmd2)' ]
}

# ---------------------------------------------------------------------------
# Backtick subshell preserved
# ---------------------------------------------------------------------------

@test "split: backtick subshell preserved" {
  collect_segments 'echo `foo | bar`'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo `foo | bar`' ]
}

@test "split: backtick with && inside preserved" {
  collect_segments 'echo `cmd1 && cmd2`'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo `cmd1 && cmd2`' ]
}

# ---------------------------------------------------------------------------
# Redirection stripping
# ---------------------------------------------------------------------------

@test "split: stdout redirect stripped" {
  collect_segments "ls > /tmp/out"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "ls" ]
}

@test "split: append redirect stripped" {
  collect_segments "echo hello >> /tmp/log"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "echo hello" ]
}

@test "split: stdin redirect stripped" {
  collect_segments "sort < /tmp/input"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "sort" ]
}

@test "split: stderr redirect 2>&1 stripped" {
  collect_segments "cmd 2>&1"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "cmd" ]
}

@test "split: stderr redirect to file stripped" {
  collect_segments "cmd 2>/dev/null"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "cmd" ]
}

@test "split: multiple redirects stripped" {
  collect_segments "cmd > /tmp/out 2>&1"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "cmd" ]
}

# ---------------------------------------------------------------------------
# Quote-aware redirection stripping (> inside quotes preserved)
# ---------------------------------------------------------------------------

@test "split: > inside double quotes not stripped" {
  collect_segments 'echo "hello > world"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "hello > world"' ]
}

@test "split: > inside single quotes not stripped" {
  collect_segments "echo 'hello > world'"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "echo 'hello > world'" ]
}

@test "split: > inside \$() subshell not stripped" {
  collect_segments 'echo "$(cat > /dev/null)"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "$(cat > /dev/null)"' ]
}

@test "split: > inside backticks not stripped" {
  collect_segments 'echo "`cat > /dev/null`"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "`cat > /dev/null`"' ]
}

@test "split: quoted > preserved but unquoted > stripped in same segment" {
  collect_segments "echo 'hello > world' > /tmp/out"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "echo 'hello > world'" ]
}

@test "split: compound with quoted > preserved correctly" {
  collect_segments 'echo "hello > world" && pwd'
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = 'echo "hello > world"' ]
  [ "${SEGMENTS[1]}" = "pwd" ]
}

@test "split: << heredoc preserved (not stripped)" {
  collect_segments 'cat <<< "hello"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'cat <<< "hello"' ]
}

# ---------------------------------------------------------------------------
# Mixed compound commands
# ---------------------------------------------------------------------------

@test "split: curl | head && echo done" {
  collect_segments "curl url | head && echo done"
  [ "$SEGMENT_COUNT" -eq 3 ]
  [ "${SEGMENTS[0]}" = "curl url" ]
  [ "${SEGMENTS[1]}" = "head" ]
  [ "${SEGMENTS[2]}" = "echo done" ]
}

@test "split: pipe with redirect in first segment" {
  collect_segments "ls 2>/dev/null | head"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "ls" ]
  [ "${SEGMENTS[1]}" = "head" ]
}

@test "split: semicolons and pipes mixed" {
  collect_segments "echo start; ls | grep foo; echo end"
  [ "$SEGMENT_COUNT" -eq 4 ]
  [ "${SEGMENTS[0]}" = "echo start" ]
  [ "${SEGMENTS[1]}" = "ls" ]
  [ "${SEGMENTS[2]}" = "grep foo" ]
  [ "${SEGMENTS[3]}" = "echo end" ]
}

# ---------------------------------------------------------------------------
# Parse failure fallback (returns original as single segment)
# ---------------------------------------------------------------------------

@test "split: unterminated single quote returns original as fallback" {
  collect_segments "echo 'unterminated"
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = "echo 'unterminated" ]
}

@test "split: unterminated double quote returns original as fallback" {
  collect_segments 'echo "unterminated'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "unterminated' ]
}

@test "split: unterminated backtick returns original as fallback" {
  collect_segments 'echo `unterminated'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo `unterminated' ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "split: empty command returns nothing" {
  collect_segments ""
  [ "$SEGMENT_COUNT" -eq 0 ]
}

@test "split: whitespace-only between operators filtered" {
  collect_segments "echo hello ;  ; echo world"
  [ "$SEGMENT_COUNT" -eq 2 ]
  [ "${SEGMENTS[0]}" = "echo hello" ]
  [ "${SEGMENTS[1]}" = "echo world" ]
}

@test "split: backslash-escaped pipe not treated as operator" {
  collect_segments 'echo foo\|bar'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo foo\|bar' ]
}

@test "split: dollar-paren inside double quotes preserved" {
  collect_segments 'echo "$(ls | head)"'
  [ "$SEGMENT_COUNT" -eq 1 ]
  [ "${SEGMENTS[0]}" = 'echo "$(ls | head)"' ]
}

# ===========================================================================
# has_redirect
# ===========================================================================

@test "redirect: simple > detected" {
  has_redirect "cat file > /tmp/out"
}

@test "redirect: >> detected" {
  has_redirect "echo ok >> /tmp/log"
}

@test "redirect: 2> stderr redirect detected" {
  has_redirect "cmd 2> /tmp/err"
}

@test "redirect: no redirect in plain command" {
  run has_redirect "cat file.txt"
  [ "$status" -eq 1 ]
}

@test "redirect: > inside single quotes not detected" {
  run has_redirect "echo 'hello > world'"
  [ "$status" -eq 1 ]
}

@test "redirect: > inside double quotes not detected" {
  run has_redirect 'echo "hello > world"'
  [ "$status" -eq 1 ]
}

@test "redirect: > inside \$() subshell not detected at top level" {
  run has_redirect 'echo $(cat > /dev/null)'
  [ "$status" -eq 1 ]
}

@test "redirect: > inside backticks not detected at top level" {
  run has_redirect 'echo `cat > /dev/null`'
  [ "$status" -eq 1 ]
}

@test "redirect: 2>&1 fd duplication not detected as file redirect" {
  run has_redirect "cmd 2>&1"
  [ "$status" -eq 1 ]
}

@test "redirect: >&2 fd duplication not detected as file redirect" {
  run has_redirect "echo error >&2"
  [ "$status" -eq 1 ]
}

@test "redirect: empty command returns 1" {
  run has_redirect ""
  [ "$status" -eq 1 ]
}

# --- Input redirect tests ---

@test "redirect: simple < detected" {
  has_redirect "wc < /etc/passwd"
}

@test "redirect: < with fd number detected" {
  has_redirect "cmd 0< /dev/null"
}

@test "redirect: < inside single quotes not detected" {
  run has_redirect "echo 'a < b'"
  [ "$status" -eq 1 ]
}

@test "redirect: < inside double quotes not detected" {
  run has_redirect 'echo "a < b"'
  [ "$status" -eq 1 ]
}

@test "redirect: << heredoc not detected as input redirect" {
  run has_redirect 'cat <<EOF
hello
EOF'
  [ "$status" -eq 1 ]
}

@test "redirect: <<< herestring not detected as input redirect" {
  run has_redirect 'cat <<< "hello world"'
  [ "$status" -eq 1 ]
}
