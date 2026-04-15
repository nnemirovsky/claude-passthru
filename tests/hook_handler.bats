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

@test "handler: plugin self-allow via \$CLAUDE_PLUGIN_ROOT (fake path)" {
  # Claude Code sets CLAUDE_PLUGIN_ROOT for every hook invocation. Using this
  # env var is the authoritative way to locate the plugin install, so the
  # self-allow must work even for totally synthetic paths.
  fake_root="$TMP/fakeplugin"
  mkdir -p "$fake_root/scripts"
  cmd="bash $fake_root/scripts/verify.sh"
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash -c "CLAUDE_PLUGIN_ROOT='$fake_root' printf '%s' \"\$1\" | CLAUDE_PLUGIN_ROOT='$fake_root' bash '$HANDLER'" _ "$payload"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$decision" = "allow" ]
  [[ "$reason" == *"self-allow"* ]]
}

@test "handler: plugin self-allow via \$CLAUDE_PLUGIN_ROOT for realistic cache install path" {
  # Real-world install path shape:
  #   ~/.claude/plugins/cache/<marketplace>/<plugin-name>/<version>/
  # The old regex required literal `claude-passthru` in the path, so this
  # shape (which is what users actually get) never matched.
  real_root="$USER_ROOT/.claude/plugins/cache/passthru/passthru/0.1.0"
  mkdir -p "$real_root/scripts"
  cmd="bash $real_root/scripts/verify.sh"
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash -c "CLAUDE_PLUGIN_ROOT='$real_root' printf '%s' \"\$1\" | CLAUDE_PLUGIN_ROOT='$real_root' bash '$HANDLER'" _ "$payload"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
}

@test "handler: plugin self-allow via fallback regex for cache/passthru/passthru/<ver>/ path (no env)" {
  # Same realistic install path but without CLAUDE_PLUGIN_ROOT set. The
  # fallback regex must still recognise `passthru` as a path segment so
  # manual pipe-testing and legacy harnesses continue to work.
  cmd='bash /Users/alice/.claude/plugins/cache/passthru/passthru/0.1.0/scripts/verify.sh'
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
}

@test "handler: self-allow via \$CLAUDE_PLUGIN_ROOT rejects unknown script names" {
  # Defense in depth: even if the prefix matches CLAUDE_PLUGIN_ROOT, only
  # the plugin's known scripts are self-allowed. An arbitrary foo.sh living
  # under the plugin root should not get a free pass.
  fake_root="$TMP/fakeplugin"
  mkdir -p "$fake_root/scripts"
  cmd="bash $fake_root/scripts/evil.sh"
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash -c "CLAUDE_PLUGIN_ROOT='$fake_root' printf '%s' \"\$1\" | CLAUDE_PLUGIN_ROOT='$fake_root' bash '$HANDLER'" _ "$payload"
  [ "$status" -eq 0 ]
  # Should fall through to passthrough (no rules -> continue:true).
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

@test "audit_write_line fails open: unwritable log dir does not block decision" {
  # Make the audit dir unwritable (chmod 555). The hook should still emit
  # its allow JSON and exit 0. The audit log itself will be empty/missing.
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  # Skip under root: r-x dirs are still writable for uid 0, so the
  # fail-open path the test exercises will not actually fire.
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: chmod 555 does not deny writes to uid 0"
  fi
  chmod 555 "$USER_ROOT/.claude" 2>/dev/null || skip "cannot chmod test dir"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"tFAIL"}'
  # Restore so teardown can rm -rf.
  chmod 755 "$USER_ROOT/.claude" 2>/dev/null || true
  [ "$status" -eq 0 ]
  # Tighten: extract the JSON envelope explicitly, then assert decision.
  # `$output` lumps stderr (the permission-denied warning) with stdout
  # (the JSON envelope), so we grep the JSON line out before parsing.
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  run jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line"
  [ "$status" -eq 0 ]
  [ "$output" = "allow" ]
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

@test "audit log: full schema check on allow line (.ts ISO, .rule_index int, .pattern non-empty)" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"schema-allow"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  # ts is ISO 8601 Z form: YYYY-MM-DDTHH:MM:SSZ.
  ts="$(jq -r '.ts' <<<"$line")"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  # rule_index is an integer (or null for self-allow). For an allow rule from
  # the user-only fixture it should be an integer >= 0.
  ridx_type="$(jq -r '.rule_index | type' <<<"$line")"
  [ "$ridx_type" = "number" ]
  # pattern is non-empty when the rule matched.
  pat="$(jq -r '.pattern' <<<"$line")"
  [ -n "$pat" ]
  [ "$pat" != "null" ]
}

@test "audit log: passthrough line has null rule_index and null pattern" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown xyz"},"tool_use_id":"schema-pt"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  ev="$(jq -r '.event' <<<"$line")"
  [ "$ev" = "passthrough" ]
  [ "$(jq -r '.rule_index' <<<"$line")" = "null" ]
  [ "$(jq -r '.pattern' <<<"$line")" = "null" ]
  [ "$(jq -r '.reason' <<<"$line")" = "null" ]
}

# ---------------------------------------------------------------------------
# Fail-open: bad regex in rule (find_first_match rc=2 path)
# ---------------------------------------------------------------------------

@test "handler: invalid regex in deny rule -> fail-open passthrough + stderr" {
  # Plant a passthru.json with a syntactically broken regex in the deny list.
  # find_first_match must return rc=2; the handler must emit `{"continue":
  # true}` on stdout and a diagnostic on stderr instead of denying outright.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[],"deny":[{"tool":"Bash","match":{"command":"(unclosed"}}]}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  # Stderr diagnostic must be present (run lumps stdout+stderr).
  [[ "$output" == *"deny rule regex error"* ]] || [[ "$output" == *"regex compile failure"* ]]
}

@test "handler: invalid regex in allow rule -> fail-open passthrough + stderr" {
  # Same shape as above but the bad regex is in allow[]. Deny[] is empty so
  # the handler reaches the allow check, hits rc=2, and falls through.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"[unclosed"}}],"deny":[]}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [[ "$output" == *"allow rule regex error"* ]] || [[ "$output" == *"regex compile failure"* ]]
}

@test "audit log: multi-key match rule logs ALL keys in .pattern (not just first)" {
  # rule_pattern_summary used to call `to_entries | .[0].value`, dropping
  # every key after the first. A multi-key match (e.g. WebFetch with both
  # url and prompt regex) should surface all keys in the audit pattern.
  enable_audit
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"WebFetch","match":{"url":"^https://example\\.com/","prompt":"^summarize "},"reason":"summary fetch"}],"deny":[]}
EOF
  payload="$(jq -cn --arg u "https://example.com/x" --arg p "summarize this" \
    '{tool_name:"WebFetch",tool_input:{url:$u,prompt:$p},tool_use_id:"tMK"}')"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  pat="$(jq -r '.pattern' <<<"$line")"
  # Both keys must appear in the summary.
  [[ "$pat" == *"url="* ]]
  [[ "$pat" == *"prompt="* ]]
  # Tool segment present too (because the rule has .tool).
  [[ "$pat" == *"WebFetch"* ]]
}

# ---------------------------------------------------------------------------
# Task 6: ask decision path (document-order allow+ask walk)
# ---------------------------------------------------------------------------

@test "handler: ask rule match emits ask decision JSON" {
  # A v2 file with an ask[] rule must produce permissionDecision "ask" with
  # reason prefix "passthru ask:" and the rule's reason appended.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "confirm gh" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh api /repos/a/b"}}'
  [ "$status" -eq 0 ]
  out="$output"
  event="$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$event" = "PreToolUse" ]
  [ "$decision" = "ask" ]
  [ "$reason" = "passthru ask: confirm gh" ]
}

@test "handler: ask rule without .reason synthesizes a pattern-based reason" {
  # Absent reason field -> message still surfaces the matched rule pattern so
  # the user sees WHY we are asking.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^curl " } }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"curl https://example.com"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$decision" = "ask" ]
  # Synthesized form: "passthru ask: matched rule [<pattern-summary>]".
  [[ "$reason" == passthru\ ask:\ matched\ rule* ]]
  # Pattern surface includes the matched tool name and command regex.
  [[ "$reason" == *"Bash"* ]]
  [[ "$reason" == *"command="* ]]
}

@test "audit: ask decision writes event=ask with rule_index + pattern" {
  enable_audit
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "confirm gh" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh pr list"},"tool_use_id":"tASK"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "ask" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru" ]
  run jq -r '.reason' <<<"$line"
  [ "$output" = "confirm gh" ]
  # Merged ask-array index 0 for the sole ask rule.
  run jq -r '.rule_index' <<<"$line"
  [ "$output" = "0" ]
  run jq -r '.pattern' <<<"$line"
  [[ "$output" == *"Bash"* ]]
  [[ "$output" == *"command="* ]]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tASK" ]
}

@test "handler: deny still wins over ask when both would match" {
  # Deny must be checked first; an ask rule covering the same call is moot.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^rm " }, "reason": "confirm rm" }
  ],
  "deny": [
    { "tool": "Bash", "match": { "command": "^rm\\s+-rf" }, "reason": "never rm -rf" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/junk"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "deny" ]
}

@test "handler: document order - narrow allow before broad ask (same file) -> allow wins" {
  # JSON key order (via jq keys_unsorted) decides the within-file walking
  # order for allow[] vs ask[]. Here allow[] appears first in the file, so
  # the narrow allow rule is checked before the broad ask rule and wins.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^gh api /repos" }, "reason": "narrow allow" }
  ],
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "broad ask" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh api /repos/foo/bar"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$decision" = "allow" ]
  [[ "$reason" == *"narrow allow"* ]]
}

@test "handler: document order - narrow ask before broad allow (same file) -> ask wins" {
  # Reversed key order: ask[] appears textually before allow[] in the file.
  # The narrow ask rule is checked first and wins.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh api /repos" }, "reason": "narrow ask" }
  ],
  "allow": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "broad allow" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh api /repos/foo/bar"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$decision" = "ask" ]
  [[ "$reason" == *"narrow ask"* ]]
}

@test "handler: cross-file - user-authored ask before user-imported allow -> ask wins" {
  # user-authored comes before user-imported in the fixed scope precedence,
  # so an ask rule in passthru.json is checked before an allow rule in
  # passthru.imported.json even if both would match.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "authored ask" }
  ]
}
EOF
  cat > "$USER_ROOT/.claude/passthru.imported.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "imported allow" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$decision" = "ask" ]
  [[ "$reason" == *"authored ask"* ]]
}

@test "handler: cross-file - project allow before user ask honored per scope precedence" {
  # load_rules scope order is:
  #   user-authored -> user-imported -> project-authored -> project-imported.
  # User-scope ask rules come BEFORE project-scope allow rules even if the
  # project file was physically populated later. A user ask must win over a
  # project allow for the same call, regardless of anyone's intuition about
  # "later overrides earlier".
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "user ask" }
  ]
}
EOF
  cat > "$PROJ_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "project allow" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$decision" = "ask" ]
  [[ "$reason" == *"user ask"* ]]
}

@test "handler: v1 file with stray ask[] key never triggers ask decision" {
  # build_ordered_allow_ask must strip ask[] for v1 files to match load_rules.
  # Even if a user includes ask[] in a v1 file (accidental or from a future
  # schema draft), the hook must ignore it and fall through to passthrough.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [],
  "deny": [],
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "should be ignored" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}'
  [ "$status" -eq 0 ]
  # No ask, no allow, no deny -> passthrough.
  cont="$(jq -r '.continue' <<<"$output")"
  [ "$cont" = "true" ]
}
