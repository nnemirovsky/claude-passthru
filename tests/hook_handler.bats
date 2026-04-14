#!/usr/bin/env bats

# tests/hook_handler.bats
# End-to-end coverage for hooks/handlers/pre-tool-use.sh.
# Every test pipes synthetic Claude Code PreToolUse payloads to the handler
# and asserts stdout JSON + exit code + stderr diagnostics. PASSTHRU_USER_HOME
# and PASSTHRU_PROJECT_DIR isolate each test from real ~/.claude; TMPDIR
# isolates the breadcrumb directory.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HANDLER="$REPO_ROOT/hooks/handlers/pre-tool-use.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures"

  TMP="$(mktemp -d -t passthru-hook.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  BCTMP="$TMP/tmp"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude" "$BCTMP"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"
  export TMPDIR="$BCTMP"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Helpers -------------------------------------------------------------------

place() {
  # $1 target path, $2 fixture name
  cp "$FIXTURES/$2" "$1"
}

run_handler() {
  # $1 = stdin JSON
  # Returns stdout in $output, status in $status.
  run bash -c "printf '%s' \"\$1\" | bash '$HANDLER'" _ "$1"
}

enable_audit() {
  touch "$USER_ROOT/.claude/passthru.audit.enabled"
}

audit_log() {
  printf '%s/.claude/passthru-audit.log\n' "$USER_ROOT"
}

# ---------------------------------------------------------------------------
# Core decision paths
# ---------------------------------------------------------------------------

@test "handler: no rule files -> passthrough" {
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
  [ "$status" -eq 0 ]
  run jq -r '.continue' <<<"$output"
  [ "$output" = "true" ]
}

@test "handler: allow match emits allow decision JSON" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
  [ "$status" -eq 0 ]
  out="$output"
  event="$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$event" = "PreToolUse" ]
  [ "$decision" = "allow" ]
  [ "$reason" = "passthru allow: safe read-only listing" ]
}

@test "handler: deny match emits deny decision JSON" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  [ "$status" -eq 0 ]
  out="$output"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$decision" = "deny" ]
  [[ "$reason" == passthru\ deny:* ]]
}

@test "handler: no match with rules present -> passthrough" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ps aux"}}'
  [ "$status" -eq 0 ]
  run jq -r '.continue' <<<"$output"
  [ "$output" = "true" ]
}

@test "handler: deny wins over allow when both would match" {
  # Craft a file where an allow AND a deny both match the same command.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "all gh" }
  ],
  "deny": [
    { "tool": "Bash", "match": { "command": "^gh pr close" }, "reason": "no auto-close" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh pr close 42"}}'
  [ "$status" -eq 0 ]
  run jq -r '.hookSpecificOutput.permissionDecision' <<<"$output"
  [ "$output" = "deny" ]
}

# ---------------------------------------------------------------------------
# Error / edge cases (fail-open)
# ---------------------------------------------------------------------------

@test "handler: malformed stdin JSON -> passthrough + stderr warning" {
  run_handler '{ not valid json'
  [ "$status" -eq 0 ]
  # $output lumps stdout+stderr under `run`; find the passthrough JSON in it.
  [[ "$output" == *'{"continue": true}'* ]]
  [[ "$output" == *"malformed"* ]] || [[ "$output" == *"warning"* ]]
}

@test "handler: empty stdin -> passthrough + stderr warning" {
  run_handler ''
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
}

@test "handler: disabled sentinel short-circuits to passthrough (even with matching deny rule)" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  touch "$USER_ROOT/.claude/passthru.disabled"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  [ "$status" -eq 0 ]
  run jq -r '.continue' <<<"$output"
  [ "$output" = "true" ]
}

@test "handler: malformed rule file -> passthrough + stderr" {
  echo '{ not json' > "$USER_ROOT/.claude/passthru.json"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
}

# ---------------------------------------------------------------------------
# Plugin self-allow
# ---------------------------------------------------------------------------

@test "handler: plugin self-allow for bash .../claude-passthru/scripts/*.sh" {
  # Synthetic realistic install path.
  cmd='bash /Users/foo/.claude/plugins/cache/owner-name/plugin-slug/1.0.0/plugins/claude-passthru/scripts/verify.sh'
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  out="$output"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$decision" = "allow" ]
  [[ "$reason" == *"self-allow"* ]]
}

@test "handler: plugin self-allow matches even when user has no rule file" {
  # Explicitly no rules present.
  cmd='bash /home/alice/.claude/plugins/cache/some-org/cc-thingz/2.0.0/plugins/claude-passthru/scripts/write-rule.sh'
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run_handler "$payload"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
}

@test "handler: plugin self-allow does NOT trigger for unrelated bash commands" {
  cmd='bash /usr/local/bin/something.sh'
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run_handler "$payload"
  cont="$(jq -r '.continue' <<<"$output")"
  [ "$cont" = "true" ]
}

# ---------------------------------------------------------------------------
# Real-world round-trip
# ---------------------------------------------------------------------------

@test "handler: gh api /repos/... with rule -> allow" {
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    { "tool": "Bash", "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" }, "reason": "forks api" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh api /repos/owner/repo/forks"}}'
  [ "$status" -eq 0 ]
  out="$output"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$decision" = "allow" ]
  [[ "$reason" == *"forks api"* ]]
}

# ---------------------------------------------------------------------------
# Audit log (opt-in)
# ---------------------------------------------------------------------------

@test "audit disabled: no log file, no breadcrumb" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"t1"}'
  [ ! -f "$(audit_log)" ]
  run bash -c "ls '$TMPDIR'/passthru-pre-*.json 2>/dev/null"
  [ -z "$output" ]
}

@test "audit enabled: allow match writes one JSONL line, no breadcrumb" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"t1"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  # Exactly one line.
  run bash -c "wc -l < '$(audit_log)'"
  [ "${output##* }" = "1" ] || [ "$output" = "1" ]
  # Valid JSON with required fields.
  line="$(head -n1 "$(audit_log)")"
  run jq -c '.' <<<"$line"
  [ "$status" -eq 0 ]
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru" ]
  run jq -r '.tool' <<<"$line"
  [ "$output" = "Bash" ]
  run jq -r '.reason' <<<"$line"
  [ "$output" = "safe read-only listing" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "t1" ]
  # No breadcrumb for non-passthrough decisions.
  run bash -c "ls '$TMPDIR'/passthru-pre-*.json 2>/dev/null"
  [ -z "$output" ]
}

@test "audit enabled: deny match writes one JSONL line, no breadcrumb" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"t2"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "deny" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "t2" ]
  run bash -c "ls '$TMPDIR'/passthru-pre-*.json 2>/dev/null"
  [ -z "$output" ]
}

@test "audit enabled: passthrough with tool_use_id writes JSONL + breadcrumb" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown xyz"},"tool_use_id":"tPT"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "passthrough" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tPT" ]
  # Breadcrumb exists and has expected shape.
  [ -f "$TMPDIR/passthru-pre-tPT.json" ]
  run jq -r '.tool' "$TMPDIR/passthru-pre-tPT.json"
  [ "$output" = "Bash" ]
  run jq -r '.tool_input.command' "$TMPDIR/passthru-pre-tPT.json"
  [ "$output" = "unknown xyz" ]
}

@test "audit enabled: passthrough without tool_use_id writes JSONL, NO breadcrumb" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown xyz"}}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "passthrough" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "null" ]
  run bash -c "ls '$TMPDIR'/passthru-pre-*.json 2>/dev/null"
  [ -z "$output" ]
}

@test "audit enabled: stale breadcrumb (>60 min) is unlinked on next invocation" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  # Plant a stale crumb by touching with a mtime older than 60 minutes.
  stale="$TMPDIR/passthru-pre-OLD.json"
  printf '{"ts":"2000-01-01T00:00:00Z","tool":"Bash","tool_input":{}}' > "$stale"
  # Use `touch -A -100` on macOS (adjust mtime by -100:00:00) or -d on GNU.
  if touch -A -020000 "$stale" 2>/dev/null; then
    :
  elif touch -d "3 hours ago" "$stale" 2>/dev/null; then
    :
  else
    # Fallback: use perl to set mtime 2 hours back.
    perl -e 'my $t=time-7200; utime $t, $t, $ARGV[0]' "$stale"
  fi
  # Invoke handler; does not matter what it decides.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tX"}'
  [ "$status" -eq 0 ]
  [ ! -f "$stale" ]
}

@test "audit enabled: self-allow is logged" {
  enable_audit
  cmd='bash /Users/x/.claude/plugins/cache/acme/passthru-mirror/1.0.0/plugins/claude-passthru/scripts/verify.sh'
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c},tool_use_id:"tSA"}')"
  run_handler "$payload"
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.reason' <<<"$line"
  [[ "$output" == *"self-allow"* ]]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tSA" ]
}

@test "audit log lines are valid JSONL (each line parses)" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  # Run three different decisions in sequence.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"a1"}'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"a2"}'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown"},"tool_use_id":"a3"}'
  # Each line must be valid JSON on its own.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    run jq -c '.' <<<"$line"
    [ "$status" -eq 0 ]
  done < "$(audit_log)"
  # And we got exactly three lines.
  n="$(wc -l < "$(audit_log)" | tr -d ' ')"
  [ "$n" -eq 3 ]
}
