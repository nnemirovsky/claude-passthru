#!/usr/bin/env bats

# tests/session_start_hook.bats
# Covers hooks/handlers/session-start.sh: the one-time bootstrap hint emitted
# at Claude Code session start when the user has native permission rules in
# ~/.claude/settings.json and has not used the plugin yet.
#
# Gating matrix:
#   * marker present                                       -> silent, no hint
#   * marker absent + passthru.json exists (user)          -> marker created, no hint
#   * marker absent + passthru.imported.json exists (user) -> marker created, no hint
#   * marker absent + passthru.json exists (project)       -> marker created, no hint
#   * marker absent + no passthru files + no settings.json -> marker created, no hint
#   * marker absent + no passthru files + settings.json with empty allow
#                                                          -> marker created, no hint
#   * marker absent + no passthru files + settings.json with N allow entries
#                                                          -> hint on stderr, marker created
#   * malformed stdin                                      -> fail open (exit 0, no crash)
#
# Hermetic via PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HANDLER="$REPO_ROOT/hooks/handlers/session-start.sh"

  TMP="$(mktemp -d -t passthru-sess-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

marker_path() {
  printf '%s/.claude/passthru.bootstrap-hint-shown\n' "$USER_ROOT"
}

# run_handler <stdin>
# Runs the hook with the given stdin payload and captures stdout, stderr,
# and status separately so we can assert on each.
run_handler() {
  local stdin="$1"
  local tmpout tmperr
  tmpout="$(mktemp -t passthru-sess-out.XXXXXX)"
  tmperr="$(mktemp -t passthru-sess-err.XXXXXX)"
  set +e
  printf '%s' "$stdin" | bash "$HANDLER" >"$tmpout" 2>"$tmperr"
  status=$?
  set -e
  STDOUT="$(cat "$tmpout")"
  STDERR="$(cat "$tmperr")"
  rm -f "$tmpout" "$tmperr"
  export status STDOUT STDERR
}

# ---------------------------------------------------------------------------
# Marker short-circuit
# ---------------------------------------------------------------------------

@test "session-start: marker present -> silent, exit 0" {
  touch "$(marker_path)"
  # Even with an allow-entry-laden settings.json present, the marker must
  # suppress the hint.
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  # stdout is just "{}\n".
  [ "$STDOUT" = "{}" ]
  # No stderr hint.
  [ -z "$STDERR" ]
}

# ---------------------------------------------------------------------------
# User already uses the plugin -> touch and exit, no hint.
# ---------------------------------------------------------------------------

@test "session-start: user passthru.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$USER_ROOT/.claude/passthru.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: user passthru.imported.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$USER_ROOT/.claude/passthru.imported.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: project passthru.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$PROJ_ROOT/.claude/passthru.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: project passthru.imported.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$PROJ_ROOT/.claude/passthru.imported.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

# ---------------------------------------------------------------------------
# No passthru files, no / empty settings -> touch and exit, no hint.
# ---------------------------------------------------------------------------

@test "session-start: no passthru files and no settings.json -> marker created, no hint" {
  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: settings.json with empty permissions.allow -> marker created, no hint" {
  printf '{"permissions":{"allow":[]}}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: settings.json with no permissions key -> marker created, no hint" {
  printf '{}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

# ---------------------------------------------------------------------------
# Actual hint path.
# ---------------------------------------------------------------------------

@test "session-start: settings.json with N allow entries -> hint on stderr mentions N and /passthru:bootstrap" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(echo hello)","mcp__context7__query-docs"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]

  # Hint mentions the count (3) and the slash command name.
  [[ "$STDERR" == *"Detected 3 importable rule(s)"* ]]
  [[ "$STDERR" == *"/passthru:bootstrap"* ]]
  [[ "$STDERR" == *"only shows once"* ]]

  # Marker is created so we do not re-hint.
  [ -f "$(marker_path)" ]
}

@test "session-start: hint fires exactly once - second run is silent" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -n "$STDERR" ]
  [ -f "$(marker_path)" ]

  # Second invocation must be silent.
  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDERR" ]
}

# ---------------------------------------------------------------------------
# Malformed stdin -> fail open.
# ---------------------------------------------------------------------------

@test "session-start: malformed stdin JSON -> exit 0, no crash" {
  # Hint conditions are met so only a stdin-parse crash would surface here.
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler 'not-json{{{'
  [ "$status" -eq 0 ]
  # stdout is still valid (either {} or the hint, but process did not crash).
  [ "$STDOUT" = "{}" ]
  # Marker must still be touched since nothing else went wrong.
  [ -f "$(marker_path)" ]
}

@test "session-start: empty stdin -> exit 0, no crash" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler ''
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -f "$(marker_path)" ]
}

# ---------------------------------------------------------------------------
# Malformed settings.json -> treat as zero, still mark, no hint, no crash.
# ---------------------------------------------------------------------------

@test "session-start: malformed settings.json -> marker created, no hint, exit 0" {
  printf 'not-json{' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ "$STDOUT" = "{}" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}
