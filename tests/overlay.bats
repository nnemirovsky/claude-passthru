#!/usr/bin/env bats

# tests/overlay.bats
# Covers the Task 7 overlay skeleton:
#   scripts/overlay.sh              - multiplexer detection + popup launch
#   scripts/overlay-dialog.sh       - TUI body (via PASSTHRU_OVERLAY_TEST_ANSWER)
#   scripts/overlay-propose-rule.sh - regex proposal for always-variants
#
# Task 7 intentionally does NOT wire the overlay into the PreToolUse hook;
# that lives in Task 8. These tests exercise the scripts in isolation via
# stub multiplexer binaries planted on PATH.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  OVERLAY="$REPO_ROOT/scripts/overlay.sh"
  DIALOG="$REPO_ROOT/scripts/overlay-dialog.sh"
  PROPOSER="$REPO_ROOT/scripts/overlay-propose-rule.sh"
  STUB_DIR="$REPO_ROOT/tests/fixtures/overlay"

  TMP="$(mktemp -d -t passthru-overlay.XXXXXX)"
  BIN="$TMP/bin"
  mkdir -p "$BIN"

  # Build a sanitized MINIMAL_PATH that includes essential utilities but
  # excludes any pre-installed tmux/kitty/wezterm (Ubuntu CI ships tmux at
  # /usr/bin/tmux). Broken-symlink masking is unreliable across bash versions
  # (Linux bash 5.1+ skips broken symlinks in command -v PATH search). Instead
  # we symlink only the utilities we need into a clean directory.
  SAFE_BIN="$TMP/safe_bin"
  mkdir -p "$SAFE_BIN"
  local cmd
  for cmd in jq perl bash cat sed awk printf tr sort uniq comm head tail \
             mkdir rm cp mv ln ls chmod date mktemp find grep wc tee touch \
             dirname basename realpath readlink env sha256sum shasum tput; do
    local src
    src="$(command -v "$cmd" 2>/dev/null || true)"
    if [ -n "$src" ] && [ -x "$src" ]; then
      ln -sf "$src" "$SAFE_BIN/$cmd"
    fi
  done
  # On Ubuntu 22.04+, /bin symlinks to /usr/bin which contains tmux.
  # Exclude all system dirs. SAFE_BIN has everything we need.
  MINIMAL_PATH="$SAFE_BIN"
  ORIGINAL_PATH="$PATH"

  # Common env for the overlay scripts.
  export PASSTHRU_OVERLAY_RESULT_FILE="$TMP/result.txt"
  # Default timeout: short so interactive-read fallbacks never hang a test.
  export PASSTHRU_OVERLAY_TIMEOUT=1

  # Make sure no stray multiplexer env var leaks in from the outer shell.
  unset TMUX
  unset KITTY_WINDOW_ID
  unset WEZTERM_PANE
  unset PASSTHRU_OVERLAY_TEST_ANSWER
  unset PASSTHRU_OVERLAY_TOOL_NAME
  unset PASSTHRU_OVERLAY_TOOL_INPUT_JSON
}

teardown() {
  # Restore PATH first so bats' internal cleanup (bats-exec-test line 205)
  # can find rm after we delete $SAFE_BIN (which lives inside $TMP).
  export PATH="$ORIGINAL_PATH"
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

plant_stub() {
  # $1 = name (tmux|kitty|wezterm). Copies the stub under the real name and
  # puts $BIN in front of PATH. Removes any mask symlink planted in setup()
  # first so the cp lands on a regular file.
  local name="$1"
  rm -f "$BIN/${name}"
  cp "$STUB_DIR/stub-${name}.sh" "$BIN/${name}"
  chmod +x "$BIN/${name}"
  export PATH="$BIN:$MINIMAL_PATH"
}

restricted_path() {
  # Force a PATH with no multiplexers. $BIN (for stubs) + $SAFE_BIN (clean
  # utils) + fallback system dirs. No tmux/kitty/wezterm anywhere.
  export PATH="$BIN:$MINIMAL_PATH"
}

# ===========================================================================
# overlay.sh detection
# ===========================================================================

@test "overlay.sh: no multiplexer env set -> exit 1 (unavailable)" {
  restricted_path
  run bash "$OVERLAY"
  [ "$status" -eq 1 ]
}

@test "overlay.sh: TMUX set + tmux stub on PATH -> launches via tmux" {
  plant_stub tmux
  export TMUX="mock/0"
  export PASSTHRU_STUB_TMUX_LOG="$TMP/tmux.log"
  export PASSTHRU_OVERLAY_TEST_ANSWER="yes_once"
  run bash "$OVERLAY"
  [ "$status" -eq 0 ]
  # Log must contain the exact popup flags we care about.
  grep -q 'display-popup' "$TMP/tmux.log"
  grep -q -- '-E' "$TMP/tmux.log"
  grep -q -- '-w 80%' "$TMP/tmux.log"
  grep -qE -- '-h [0-9]+' "$TMP/tmux.log"
  # Dialog ran -> result file has the verdict.
  [ -f "$TMP/result.txt" ]
  run cat "$TMP/result.txt"
  [ "$output" = "yes_once" ]
}

@test "overlay.sh: TMUX set but tmux binary missing -> exit 1 (fall through)" {
  restricted_path
  export TMUX="mock/0"
  # No kitty/wezterm planted either -> nothing available at all.
  run bash "$OVERLAY"
  [ "$status" -eq 1 ]
}

@test "overlay.sh: TMUX set (no tmux on PATH) but kitty stub planted -> uses kitty" {
  # Covers the fall-through order: $TMUX is set but no tmux binary, so
  # detection should progress to the next candidate that has both its env
  # var set AND a binary on PATH.
  plant_stub kitty
  export TMUX="mock/0"
  export KITTY_WINDOW_ID="42"
  export PASSTHRU_STUB_KITTY_LOG="$TMP/kitty.log"
  export PASSTHRU_OVERLAY_TEST_ANSWER="yes_once"
  run bash "$OVERLAY"
  [ "$status" -eq 0 ]
  grep -q 'launch' "$TMP/kitty.log"
  grep -q -- '--type=overlay' "$TMP/kitty.log"
  [ -f "$TMP/result.txt" ]
}

@test "overlay.sh: KITTY_WINDOW_ID set + kitty stub on PATH -> launches via kitty" {
  plant_stub kitty
  export KITTY_WINDOW_ID="99"
  export PASSTHRU_STUB_KITTY_LOG="$TMP/kitty.log"
  export PASSTHRU_OVERLAY_TEST_ANSWER="no_once"
  run bash "$OVERLAY"
  [ "$status" -eq 0 ]
  grep -q -- '--type=overlay' "$TMP/kitty.log"
  grep -q -- '--no-response' "$TMP/kitty.log"
  run cat "$TMP/result.txt"
  [ "$output" = "no_once" ]
}

@test "overlay.sh: WEZTERM_PANE set + wezterm stub on PATH -> launches via wezterm" {
  plant_stub wezterm
  export WEZTERM_PANE="7"
  export PASSTHRU_STUB_WEZTERM_LOG="$TMP/wezterm.log"
  export PASSTHRU_OVERLAY_TEST_ANSWER="yes_always"
  export PASSTHRU_OVERLAY_TOOL_NAME="Bash"
  export PASSTHRU_OVERLAY_TOOL_INPUT_JSON='{"command":"gh api /foo"}'
  run bash "$OVERLAY"
  [ "$status" -eq 0 ]
  grep -q 'split-pane' "$TMP/wezterm.log"
  [ -f "$TMP/result.txt" ]
  # Two lines: verdict + rule JSON.
  run head -1 "$TMP/result.txt"
  [ "$output" = "yes_always" ]
}

@test "overlay.sh: no env vars at all -> exit 1 even with stubs on PATH" {
  plant_stub tmux
  # Do NOT export TMUX. Detection requires BOTH the env var and the binary.
  run bash "$OVERLAY"
  [ "$status" -eq 1 ]
}

@test "overlay.sh: missing PASSTHRU_OVERLAY_RESULT_FILE -> exit 2" {
  plant_stub tmux
  export TMUX="mock/0"
  unset PASSTHRU_OVERLAY_RESULT_FILE
  run bash "$OVERLAY"
  [ "$status" -eq 2 ]
}

# ===========================================================================
# overlay-dialog.sh TEST_ANSWER short-circuit
# ===========================================================================

@test "overlay-dialog: yes_once writes verdict line only, no rule" {
  export PASSTHRU_OVERLAY_TEST_ANSWER="yes_once"
  export PASSTHRU_OVERLAY_TOOL_NAME="Bash"
  export PASSTHRU_OVERLAY_TOOL_INPUT_JSON='{"command":"ls"}'
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
  [ -f "$PASSTHRU_OVERLAY_RESULT_FILE" ]
  run cat "$PASSTHRU_OVERLAY_RESULT_FILE"
  [ "$output" = "yes_once" ]
  # Exactly one line (no trailing rule JSON).
  run wc -l < "$PASSTHRU_OVERLAY_RESULT_FILE"
  # wc -l output can be " 1" with spaces; strip.
  [ "$(printf '%s' "$output" | tr -d ' ')" = "1" ]
}

@test "overlay-dialog: no_once writes verdict line only, no rule" {
  export PASSTHRU_OVERLAY_TEST_ANSWER="no_once"
  export PASSTHRU_OVERLAY_TOOL_NAME="Bash"
  export PASSTHRU_OVERLAY_TOOL_INPUT_JSON='{"command":"rm -rf /"}'
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
  run cat "$PASSTHRU_OVERLAY_RESULT_FILE"
  [ "$output" = "no_once" ]
}

@test "overlay-dialog: yes_always writes verdict + proposed allow rule JSON" {
  export PASSTHRU_OVERLAY_TEST_ANSWER="yes_always"
  export PASSTHRU_OVERLAY_TOOL_NAME="Bash"
  export PASSTHRU_OVERLAY_TOOL_INPUT_JSON='{"command":"gh api /repos/foo"}'
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
  [ -f "$PASSTHRU_OVERLAY_RESULT_FILE" ]
  # First line: verdict. Second line: rule JSON.
  run head -1 "$PASSTHRU_OVERLAY_RESULT_FILE"
  [ "$output" = "yes_always" ]
  rule="$(sed -n '2p' "$PASSTHRU_OVERLAY_RESULT_FILE")"
  run jq -e '.tool == "Bash" and (.match.command | type == "string")' <<<"$rule"
  [ "$status" -eq 0 ]
}

@test "overlay-dialog: no_always writes verdict + proposed rule JSON (deny path)" {
  export PASSTHRU_OVERLAY_TEST_ANSWER="no_always"
  export PASSTHRU_OVERLAY_TOOL_NAME="Bash"
  export PASSTHRU_OVERLAY_TOOL_INPUT_JSON='{"command":"curl evil.com"}'
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
  run head -1 "$PASSTHRU_OVERLAY_RESULT_FILE"
  [ "$output" = "no_always" ]
  rule="$(sed -n '2p' "$PASSTHRU_OVERLAY_RESULT_FILE")"
  run jq -e 'type == "object"' <<<"$rule"
  [ "$status" -eq 0 ]
}

@test "overlay-dialog: cancel does NOT write the result file" {
  export PASSTHRU_OVERLAY_TEST_ANSWER="cancel"
  export PASSTHRU_OVERLAY_TOOL_NAME="Bash"
  export PASSTHRU_OVERLAY_TOOL_INPUT_JSON='{"command":"ls"}'
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
  # Caller's contract: absent or empty file == cancel.
  [ ! -f "$PASSTHRU_OVERLAY_RESULT_FILE" ]
}

@test "overlay-dialog: unknown TEST_ANSWER -> treat as cancel (no file)" {
  export PASSTHRU_OVERLAY_TEST_ANSWER="nonsense_value"
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
  [ ! -f "$PASSTHRU_OVERLAY_RESULT_FILE" ]
}

@test "overlay-dialog: missing RESULT_FILE env var -> exits cleanly" {
  unset PASSTHRU_OVERLAY_RESULT_FILE
  export PASSTHRU_OVERLAY_TEST_ANSWER="yes_once"
  run bash "$DIALOG"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# overlay-propose-rule.sh category coverage
# ===========================================================================

@test "propose-rule: Bash command -> ^<first-word>\\s match" {
  run bash "$PROPOSER" "Bash" '{"command":"gh api /repos/foo"}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "Bash" ]
  # Re-run to grab match.command.
  run bash "$PROPOSER" "Bash" '{"command":"gh api /repos/foo"}'
  run jq -r '.match.command' <<<"$output"
  [ "$output" = "^gh\\s" ]
}

@test "propose-rule: Bash rm command keeps first token" {
  run bash "$PROPOSER" "Bash" '{"command":"rm -rf /tmp/foo"}'
  [ "$status" -eq 0 ]
  run jq -r '.match.command' <<<"$output"
  [ "$output" = "^rm\\s" ]
}

@test "propose-rule: Read file_path -> parent-dir prefix match" {
  run bash "$PROPOSER" "Read" '{"file_path":"/Users/me/proj/src/file.ts"}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^(Read|Edit|Write)$" ]
  run bash "$PROPOSER" "Read" '{"file_path":"/Users/me/proj/src/file.ts"}'
  run jq -r '.match.file_path' <<<"$output"
  [ "$output" = "^/Users/me/proj/src/" ]
}

@test "propose-rule: Edit file_path uses same tri-tool regex" {
  run bash "$PROPOSER" "Edit" '{"file_path":"/tmp/work/notes.md"}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^(Read|Edit|Write)$" ]
}

@test "propose-rule: Write file_path uses same tri-tool regex" {
  run bash "$PROPOSER" "Write" '{"file_path":"/tmp/work/notes.md"}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^(Read|Edit|Write)$" ]
}

@test "propose-rule: WebFetch URL -> scheme+host match" {
  run bash "$PROPOSER" "WebFetch" '{"url":"https://example.com/api/foo"}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^(WebFetch|WebSearch)$" ]
  run bash "$PROPOSER" "WebFetch" '{"url":"https://example.com/api/foo"}'
  run jq -r '.match.url' <<<"$output"
  [ "$output" = "^https?://example\\.com" ]
}

@test "propose-rule: WebSearch URL uses same tool regex" {
  run bash "$PROPOSER" "WebSearch" '{"url":"http://sub.example.com/q?x=1"}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^(WebFetch|WebSearch)$" ]
  run bash "$PROPOSER" "WebSearch" '{"url":"http://sub.example.com/q?x=1"}'
  run jq -r '.match.url' <<<"$output"
  [ "$output" = "^https?://sub\\.example\\.com" ]
}

@test "propose-rule: MCP tool -> server-wide tool regex, no match block" {
  run bash "$PROPOSER" "mcp__github__list_prs" ''
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^mcp__github__" ]
  run bash "$PROPOSER" "mcp__github__list_prs" ''
  run jq -r 'has("match")' <<<"$output"
  [ "$output" = "false" ]
}

@test "propose-rule: unknown tool -> exact-name fallback rule" {
  run bash "$PROPOSER" "Custom" ''
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^Custom$" ]
  run bash "$PROPOSER" "Custom" ''
  run jq -r 'has("match")' <<<"$output"
  [ "$output" = "false" ]
}

@test "propose-rule: Bash without command field -> exact-name fallback" {
  run bash "$PROPOSER" "Bash" '{}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^Bash$" ]
}

@test "propose-rule: Read without file_path field -> exact-name fallback" {
  run bash "$PROPOSER" "Read" '{}'
  [ "$status" -eq 0 ]
  run jq -r '.tool' <<<"$output"
  [ "$output" = "^Read$" ]
}

# ===========================================================================
# Concurrency: two overlay invocations with distinct result files
# ===========================================================================

@test "overlay.sh: concurrent invocations with distinct result files do not cross-talk" {
  plant_stub tmux
  export TMUX="mock/0"
  export PASSTHRU_STUB_TMUX_LOG="$TMP/tmux.log"

  local R1="$TMP/r1.txt" R2="$TMP/r2.txt"

  (
    PASSTHRU_OVERLAY_RESULT_FILE="$R1" \
    PASSTHRU_OVERLAY_TEST_ANSWER="yes_once" \
    bash "$OVERLAY" >/dev/null 2>&1
  ) &
  local PID1=$!
  (
    PASSTHRU_OVERLAY_RESULT_FILE="$R2" \
    PASSTHRU_OVERLAY_TEST_ANSWER="no_once" \
    bash "$OVERLAY" >/dev/null 2>&1
  ) &
  local PID2=$!

  wait "$PID1"
  wait "$PID2"

  [ -f "$R1" ]
  [ -f "$R2" ]
  run cat "$R1"
  [ "$output" = "yes_once" ]
  run cat "$R2"
  [ "$output" = "no_once" ]
}

# ===========================================================================
# Partial write / cancel handling
# ===========================================================================

@test "overlay.sh: cancel inside dialog leaves no result file" {
  plant_stub tmux
  export TMUX="mock/0"
  export PASSTHRU_STUB_TMUX_LOG="$TMP/tmux.log"
  export PASSTHRU_OVERLAY_TEST_ANSWER="cancel"
  run bash "$OVERLAY"
  [ "$status" -eq 0 ]
  [ ! -f "$PASSTHRU_OVERLAY_RESULT_FILE" ]
}
