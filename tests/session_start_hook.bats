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
#                                                          -> hint on stdout, marker created
#   * malformed stdin                                      -> fail open (exit 0, no crash)
#
# Hermetic via PASSTHRU_USER_HOME / PASSTHRU_PROJECT_DIR.
#
# Contract notes:
#   Per Claude Code docs, the SessionStart hook surfaces its `systemMessage`
#   JSON field in the session view as "SessionStart:startup says: <text>".
#   The handler therefore emits `{"systemMessage":"<text>"}` on stdout when
#   the hint fires, and emits nothing on stdout in all other cases -
#   including the marker-present short-circuit - so the session header stays
#   clean. Plain text stdout does NOT surface, so earlier versions of this
#   hook were silently ignored by Claude Code.

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

# assert_hint_envelope: verify STDOUT is a well-formed JSON object with
# `.systemMessage` containing the passthru hint fragments. Requires jq.
assert_hint_envelope() {
  # Must be parseable as JSON.
  jq -e '.' <<<"$STDOUT" >/dev/null
  # Must have a systemMessage string field.
  jq -e '.systemMessage | type == "string"' <<<"$STDOUT" >/dev/null
  local msg
  msg="$(jq -r '.systemMessage' <<<"$STDOUT")"
  [[ "$msg" == *"/passthru:bootstrap"* ]]
  [[ "$msg" == *"only shows once"* ]]
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
  # stdout must be empty - no JSON envelope in the session header.
  [ -z "$STDOUT" ]
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
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: user passthru.imported.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$USER_ROOT/.claude/passthru.imported.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: project passthru.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$PROJ_ROOT/.claude/passthru.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: project passthru.imported.json exists -> marker created, no hint" {
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' > "$USER_ROOT/.claude/settings.json"
  printf '{"version":1,"allow":[],"deny":[]}\n' > "$PROJ_ROOT/.claude/passthru.imported.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

# ---------------------------------------------------------------------------
# No passthru files, no / empty settings -> touch and exit, no hint.
# ---------------------------------------------------------------------------

@test "session-start: no passthru files and no settings.json -> marker created, no hint" {
  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: settings.json with empty permissions.allow -> marker created, no hint" {
  printf '{"permissions":{"allow":[]}}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

@test "session-start: settings.json with no permissions key -> marker created, no hint" {
  printf '{}\n' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}

# ---------------------------------------------------------------------------
# Actual hint path.
# ---------------------------------------------------------------------------

@test "session-start: settings.json with N allow entries -> hint systemMessage mentions N and /passthru:bootstrap" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)","Bash(echo hello)","mcp__context7__query-docs"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]

  # Hint lands on stdout wrapped in the Claude Code JSON contract so it
  # surfaces as "SessionStart:startup says: <text>".
  jq -e '.' <<<"$STDOUT" >/dev/null
  local msg
  msg="$(jq -r '.systemMessage' <<<"$STDOUT")"
  [[ "$msg" == *"3 importable"* ]]
  [[ "$msg" == *"/passthru:bootstrap"* ]]
  [[ "$msg" == *"only shows once"* ]]

  # Only the systemMessage key should be present - keep the envelope
  # minimal so we do not accidentally inject context.
  local keys
  keys="$(jq -r 'keys | join(",")' <<<"$STDOUT")"
  [ "$keys" = "systemMessage" ]

  # Nothing on stderr in the happy path.
  [ -z "$STDERR" ]

  # Marker is created so we do not re-hint.
  [ -f "$(marker_path)" ]
}

@test "session-start: hint fires exactly once - second run is silent" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -n "$STDOUT" ]
  assert_hint_envelope
  [ -f "$(marker_path)" ]

  # Second invocation must be silent on both streams.
  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
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
  # The hint should still fire (stdin is redirected to /dev/null, never parsed).
  assert_hint_envelope
  # Marker must still be touched since nothing else went wrong.
  [ -f "$(marker_path)" ]
}

@test "session-start: empty stdin -> exit 0, no crash" {
  printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' \
    > "$USER_ROOT/.claude/settings.json"

  run_handler ''
  [ "$status" -eq 0 ]
  assert_hint_envelope
  [ -f "$(marker_path)" ]
}

# ---------------------------------------------------------------------------
# Malformed settings.json -> treat as zero, still mark, no hint, no crash.
# ---------------------------------------------------------------------------

@test "session-start: malformed settings.json -> marker created, no hint, exit 0" {
  printf 'not-json{' > "$USER_ROOT/.claude/settings.json"

  run_handler '{}'
  [ "$status" -eq 0 ]
  [ -z "$STDOUT" ]
  [ -z "$STDERR" ]
  [ -f "$(marker_path)" ]
}
