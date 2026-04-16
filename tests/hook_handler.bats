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

  # Scrub multiplexer env vars + any overlay mock sentinels so overlay
  # detection stays deterministic across CI and dev machines (local tmux
  # sessions otherwise leak the TMUX var into the handler subprocess).
  unset TMUX
  unset KITTY_WINDOW_ID
  unset WEZTERM_PANE
  unset PASSTHRU_OVERLAY_MOCK_ANSWER
  unset PASSTHRU_OVERLAY_MOCK_RULE_JSON
  unset PASSTHRU_OVERLAY_MOCK_EXIT_CODE
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

@test "handler: no rule files + no multiplexer -> overlay fallback emits ask" {
  # Task 8: no rule match + mode does not auto-allow Bash -> overlay path.
  # With no multiplexer available in the test env, the overlay fallback
  # emits permissionDecision:"ask" so CC surfaces its native dialog.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
  [ "$status" -eq 0 ]
  # Stderr warning about missing multiplexer is lumped into $output by `run`.
  [[ "$output" == *"no supported multiplexer"* ]]
  # Extract the JSON envelope (stdout) from the mixed stdout+stderr output.
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
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

@test "handler: no match with rules present -> overlay fallback emits ask" {
  # Task 8: same rationale as the no-rule-files variant. A non-matching
  # command with rules on disk still ends up on the overlay path; in the
  # test env (no multiplexer) that collapses to permissionDecision:"ask".
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ps aux"}}'
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
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
  # Unrelated command falls past the self-allow regex and proceeds to the
  # overlay path. In the test env (no multiplexer) the overlay fallback
  # emits permissionDecision:"ask" rather than the pre-Task-8 passthrough.
  cmd='bash /usr/local/bin/something.sh'
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run_handler "$payload"
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
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
  # Post-Task-8: unrecognised command falls through to overlay path. With no
  # multiplexer in test env, overlay fallback emits permissionDecision:"ask".
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
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

@test "audit enabled: no-match -> ask event (overlay unavailable fallback) with tool_use_id" {
  # Post-Task-8: no rule match + default mode + Bash (not auto-allowed) +
  # no multiplexer in test env -> overlay fallback emits ask. Audit log
  # records event=ask and ALSO writes a breadcrumb so post-tool-use.sh can
  # classify the native-dialog outcome into an asked_* event. (Pre-fix the
  # breadcrumb was missing on every ask-emit path; see docs/rule-format.md:169
  # for the behavior contract.)
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown xyz"},"tool_use_id":"tPT"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "ask" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tPT" ]
  # Breadcrumb MUST exist so PostToolUse can classify the native-dialog answer.
  [ -f "$TMPDIR/passthru-pre-tPT.json" ]
}

@test "audit enabled: no-match without tool_use_id writes JSONL ask event" {
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown xyz"}}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "ask" ]
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

@test "audit log: ask line from overlay-unavailable fallback has null rule_index and null pattern" {
  # Post-Task-8: the no-match fallback emits ask with no rule fields (there
  # was no matching rule). rule_index and pattern stay null; reason carries
  # the overlay-failure tag for diagnosability.
  place "$USER_ROOT/.claude/passthru.json" "user-only.json"
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"unknown xyz"},"tool_use_id":"schema-pt"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  ev="$(jq -r '.event' <<<"$line")"
  [ "$ev" = "ask" ]
  [ "$(jq -r '.rule_index' <<<"$line")" = "null" ]
  [ "$(jq -r '.pattern' <<<"$line")" = "null" ]
  # reason is a non-null diagnostic ("overlay unavailable").
  reason_val="$(jq -r '.reason' <<<"$line")"
  [ "$reason_val" != "null" ]
  [ -n "$reason_val" ]
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
  # Post-Task-8: overlay unavailable warning is emitted on stderr and lumped
  # into $output by `run`. Extract the JSON envelope explicitly.
  out="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$out" ]
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
  out="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$out" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
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
  out="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$out" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
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
  out="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$out" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
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
  out="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$out" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$decision" = "ask" ]
  [[ "$reason" == *"user ask"* ]]
}

@test "handler: v1 file with stray ask[] key never triggers ask-rule decision" {
  # build_ordered_allow_ask must strip ask[] for v1 files to match load_rules.
  # Even if a user includes ask[] in a v1 file (accidental or from a future
  # schema draft), the hook must ignore it. Post-Task-8 the effective fall
  # through is overlay path: we assert the ask decision we DO emit is the
  # no-match fallback (overlay unavailable), NOT a decision attributed to
  # the stray ask rule (no "should be ignored" reason leaks through).
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
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  # The stray ask rule's reason must NOT surface - the v1 parser dropped it.
  [[ "$reason" != *"should be ignored"* ]]
  # The fallback reason references "no rule matched" (default-mode flow).
  [[ "$reason" == *"no rule matched"* ]]
}

# ===========================================================================
# Task 8: permission-mode replication + overlay invocation
# ===========================================================================

# Helpers for Task 8 tests --------------------------------------------------

# make_mode_payload <tool_name> <tool_input_json> <mode> [cwd]
# Emits a PreToolUse stdin payload with permission_mode + cwd populated.
make_mode_payload() {
  local tool="$1" ti="$2" mode="$3" cwd="${4:-}"
  jq -cn --arg t "$tool" --argjson ti "$ti" --arg m "$mode" --arg c "$cwd" \
    '{tool_name:$t, tool_input:$ti, permission_mode:$m, cwd:(if $c == "" then null else $c end)}'
}

# setup_overlay_stub <verdict> [exit_code] [rule_json]
# Plants a stub plugin root with a mock scripts/overlay.sh that writes the
# given verdict (and optional rule_json line for always-variants) to
# $PASSTHRU_OVERLAY_RESULT_FILE. Exports CLAUDE_PLUGIN_ROOT so the hook
# discovers the stub overlay instead of the real one. Other plugin files
# (hooks/common.sh, scripts/write-rule.sh, scripts/verify.sh) symlink to
# the real repo so the hook's support scripts still work.
#
# Also arranges the multiplexer presence the overlay_available helper
# requires: exports TMUX and places a no-op tmux binary in $TMP/bin on PATH.
# Without these, overlay_available() returns false and the hook skips the
# stub entirely (native-dialog fallback), which is rarely what tests want.
#
# A non-zero exit_code simulates a launch failure: the stub writes nothing
# and exits with the given code. rule_json is only used when verdict is
# yes_always or no_always.
setup_overlay_stub() {
  local verdict="$1" exit_code="${2:-0}" rule_json="${3:-}"
  local stub_root="$TMP/stub-plugin"
  mkdir -p "$stub_root/hooks/handlers" "$stub_root/scripts"
  # Symlink the real files so the hook finds them through CLAUDE_PLUGIN_ROOT.
  ln -sfn "$REPO_ROOT/hooks/common.sh" "$stub_root/hooks/common.sh"
  ln -sfn "$REPO_ROOT/hooks/handlers/pre-tool-use.sh" "$stub_root/hooks/handlers/pre-tool-use.sh"
  ln -sfn "$REPO_ROOT/hooks/handlers/post-tool-use.sh" "$stub_root/hooks/handlers/post-tool-use.sh"
  ln -sfn "$REPO_ROOT/scripts/write-rule.sh" "$stub_root/scripts/write-rule.sh"
  ln -sfn "$REPO_ROOT/scripts/verify.sh" "$stub_root/scripts/verify.sh"

  local stub_overlay="$stub_root/scripts/overlay.sh"
  if [ "$exit_code" != "0" ]; then
    # Launch-failure path: exit non-zero without writing a result file.
    cat > "$stub_overlay" <<STUB
#!/usr/bin/env bash
exit ${exit_code}
STUB
  else
    # Write verdict + optional rule JSON, then exit 0. The hook reads
    # \$PASSTHRU_OVERLAY_RESULT_FILE afterwards.
    local rule_literal=""
    if [ -n "$rule_json" ]; then
      # Pass the rule JSON through printf as a literal string (escape \$ so
      # the stub itself does not try to expand it).
      rule_literal="printf '%s\\n' '$rule_json' >> \"\$PASSTHRU_OVERLAY_RESULT_FILE\""
    fi
    cat > "$stub_overlay" <<STUB
#!/usr/bin/env bash
: "\${PASSTHRU_OVERLAY_RESULT_FILE:?}"
mkdir -p "\$(dirname "\$PASSTHRU_OVERLAY_RESULT_FILE")" 2>/dev/null || true
printf '%s\\n' '${verdict}' > "\$PASSTHRU_OVERLAY_RESULT_FILE"
${rule_literal}
# Touch a log file so tests can assert the stub ran.
if [ -n "\${PASSTHRU_OVERLAY_STUB_LOG:-}" ]; then
  {
    printf 'invoked verdict=%s tool=%s tool_input=%s\\n' \\
      '${verdict}' "\${PASSTHRU_OVERLAY_TOOL_NAME:-}" "\${PASSTHRU_OVERLAY_TOOL_INPUT_JSON:-}"
  } >> "\$PASSTHRU_OVERLAY_STUB_LOG" 2>/dev/null || true
fi
exit 0
STUB
  fi
  chmod +x "$stub_overlay"

  export CLAUDE_PLUGIN_ROOT="$stub_root"

  # Arrange multiplexer presence for overlay_available. TMUX + a no-op
  # tmux binary on PATH is the simplest combo. Tests that deliberately
  # test "no multiplexer" use setup_overlay_refuses_invocation instead.
  local bin_dir="$TMP/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/tmux" <<'TMUXSTUB'
#!/usr/bin/env bash
exit 0
TMUXSTUB
  chmod +x "$bin_dir/tmux"
  export PATH="$bin_dir:$PATH"
  export TMUX="mock/0"
}

# setup_overlay_refuses_invocation: plants a stub overlay.sh that writes a
# marker file on every invocation (so tests assert the stub NEVER ran).
setup_overlay_refuses_invocation() {
  local stub_root="$TMP/stub-plugin"
  mkdir -p "$stub_root/hooks/handlers" "$stub_root/scripts"
  ln -sfn "$REPO_ROOT/hooks/common.sh" "$stub_root/hooks/common.sh"
  ln -sfn "$REPO_ROOT/hooks/handlers/pre-tool-use.sh" "$stub_root/hooks/handlers/pre-tool-use.sh"
  ln -sfn "$REPO_ROOT/scripts/write-rule.sh" "$stub_root/scripts/write-rule.sh"
  ln -sfn "$REPO_ROOT/scripts/verify.sh" "$stub_root/scripts/verify.sh"

  cat > "$stub_root/scripts/overlay.sh" <<STUB
#!/usr/bin/env bash
touch "\${TMP:-/tmp}/overlay-stub-RAN"
exit 0
STUB
  chmod +x "$stub_root/scripts/overlay.sh"
  export CLAUDE_PLUGIN_ROOT="$stub_root"
}

run_handler_in_stub_root() {
  # Same as run_handler but inherits CLAUDE_PLUGIN_ROOT.
  run bash -c "printf '%s' \"\$1\" | bash '$CLAUDE_PLUGIN_ROOT/hooks/handlers/pre-tool-use.sh'" _ "$1"
}

# bypassPermissions mode: overlay is still consulted ----------------------------

@test "mode: bypassPermissions + any tool -> overlay path entered" {
  # Mode-based auto-allow is removed. All non-internal tools go through
  # the overlay regardless of permission_mode.
  setup_overlay_stub "yes_once"
  payload="$(make_mode_payload 'Bash' '{"command":"rm -rf /tmp/foo"}' 'bypassPermissions')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

# acceptEdits mode: overlay is still consulted ---------------------------------

@test "mode: acceptEdits + Write inside cwd -> overlay path entered" {
  setup_overlay_stub "yes_once"
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/foo.ts" '{file_path:$fp,content:"x"}')"
  payload="$(make_mode_payload 'Write' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "mode: acceptEdits + Write OUTSIDE cwd -> overlay path entered" {
  # file_path is /tmp/elsewhere (definitely not under PROJ_ROOT). Mode does
  # NOT auto-allow, so we fall through to overlay. Stub emits yes_once.
  setup_overlay_stub "yes_once"
  ti='{"file_path":"/tmp/elsewhere/foo.ts","content":"x"}'
  payload="$(make_mode_payload 'Write' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "mode: acceptEdits + Read (non-edit tool) -> overlay path entered" {
  # Read is NOT in the acceptEdits allow-list; acceptEdits only covers
  # Write/Edit/NotebookEdit/MultiEdit. A Read call falls through to overlay.
  setup_overlay_stub "yes_once"
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/foo.ts" '{file_path:$fp}')"
  payload="$(make_mode_payload 'Read' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

# default mode: all tools go to overlay ----------------------------------------

@test "mode: default + Read inside cwd -> overlay path entered" {
  setup_overlay_stub "yes_once"
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/file.ts" '{file_path:$fp}')"
  payload="$(make_mode_payload 'Read' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "mode: default + Read outside cwd -> overlay path entered" {
  setup_overlay_stub "yes_once"
  ti='{"file_path":"/etc/hosts"}'
  payload="$(make_mode_payload 'Read' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "mode: default + Bash -> overlay path entered (Bash never auto-allowed)" {
  # Bash is inherently never auto-allowed in default mode - always consult
  # the overlay (or native fallback).
  setup_overlay_stub "yes_once"
  ti='{"command":"gh api /repos/a/b"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

# plan mode: all tools go to overlay -------------------------------------------

@test "mode: plan + Read -> overlay path entered" {
  setup_overlay_stub "yes_once"
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/file.ts" '{file_path:$fp}')"
  payload="$(make_mode_payload 'Read' "$ti" 'plan' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "mode: plan + Write -> overlay path entered" {
  # plan mode restricts writes; the overlay (or native fallback) gates them.
  setup_overlay_stub "no_once"
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/foo.ts" '{file_path:$fp,content:"x"}')"
  payload="$(make_mode_payload 'Write' "$ti" 'plan' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "deny" ]
}

# WebFetch and WebSearch go through the overlay --------------------------------

@test "mode: default + WebFetch -> overlay path entered" {
  setup_overlay_stub "no_once"
  ti='{"url":"https://example.com"}'
  payload="$(make_mode_payload 'WebFetch' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  # Overlay returned no_once -> deny.
  [ "$decision" = "deny" ]
}

@test "mode: default + WebSearch -> overlay path entered" {
  setup_overlay_stub "no_once"
  ti='{"query":"what is claude code"}'
  payload="$(make_mode_payload 'WebSearch' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "deny" ]
}

# Path-traversal safety ------------------------------------------------------

@test "mode: acceptEdits + file_path with ../ traversal is NOT auto-allowed" {
  # $PROJ_ROOT/../outside literally starts with $PROJ_ROOT/ but resolves
  # OUTSIDE cwd. permission_mode_auto_allows must reject these so crafted
  # tool_inputs cannot sneak past the prefix check.
  setup_overlay_stub "no_once"
  ti="$(jq -cn --arg fp "$PROJ_ROOT/../outside/secret.txt" '{file_path:$fp,content:"x"}')"
  payload="$(make_mode_payload 'Write' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  # Decision came from overlay (stub returned no_once). Auto-allow was
  # rejected -> overlay was consulted -> deny.
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "deny" ]
}

@test "mode: symlink inside cwd -> overlay path entered (no auto-allow shortcut)" {
  # Mode-based auto-allow is removed. The symlink prefix-check known
  # limitation is no longer relevant because all tools go through the
  # overlay regardless of path.
  setup_overlay_stub "yes_once"
  mkdir -p "$PROJ_ROOT/src"
  fp="$PROJ_ROOT/src/linked-file.ts"
  ti="$(jq -cn --arg fp "$fp" '{file_path:$fp,content:"x"}')"
  payload="$(make_mode_payload 'Write' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

# Overlay-disabled sentinel --------------------------------------------------

@test "overlay: passthru.overlay.disabled sentinel -> native ask, overlay NOT invoked" {
  # When the user opts out via the sentinel, the hook must skip the overlay
  # entirely and emit permissionDecision:"ask". The stub overlay marker
  # file must NOT be created.
  setup_overlay_refuses_invocation
  touch "$USER_ROOT/.claude/passthru.overlay.disabled"
  # Bash in default mode -> no auto-allow, would go to overlay.
  ti='{"command":"ls"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
  [ ! -e "$TMP/overlay-stub-RAN" ]
}

# Overlay-unavailable path --------------------------------------------------

@test "overlay: no multiplexer env -> stderr warning + native ask, overlay NOT invoked" {
  # No TMUX/KITTY/WEZTERM -> overlay_available returns 1 -> we warn to
  # stderr and emit permissionDecision:"ask". The stub must NOT run.
  setup_overlay_refuses_invocation
  ti='{"command":"ls"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no supported multiplexer"* ]]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
  [ ! -e "$TMP/overlay-stub-RAN" ]
}

# Overlay invocation (via stub PATH / CLAUDE_PLUGIN_ROOT) --------------------

@test "overlay: yes_once verdict -> allow emitted" {
  setup_overlay_stub "yes_once"
  export TMUX="mock/0"
  # Put a tmux binary on PATH so overlay_available returns 0.
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"gh api /repos/a/b"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"overlay"* ]]
}

@test "overlay: no_once verdict -> deny emitted" {
  setup_overlay_stub "no_once"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"curl evil.example"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "deny" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"overlay"* ]]
}

@test "overlay: yes_always verdict writes rule to user/allow AND emits allow" {
  rule_json='{"tool":"Bash","match":{"command":"^gh "},"reason":"overlay yes_always"}'
  setup_overlay_stub "yes_always" 0 "$rule_json"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"gh api /repos/a/b"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  # Rule landed in user-scope passthru.json under allow[].
  [ -f "$USER_ROOT/.claude/passthru.json" ]
  match_cmd="$(jq -r '.allow[-1].match.command' "$USER_ROOT/.claude/passthru.json")"
  [ "$match_cmd" = "^gh " ]
  tool_val="$(jq -r '.allow[-1].tool' "$USER_ROOT/.claude/passthru.json")"
  [ "$tool_val" = "Bash" ]
}

@test "overlay: no_always verdict writes rule to user/deny AND emits deny" {
  rule_json='{"tool":"Bash","match":{"command":"^curl "},"reason":"overlay no_always"}'
  setup_overlay_stub "no_always" 0 "$rule_json"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"curl evil.example"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "deny" ]
  [ -f "$USER_ROOT/.claude/passthru.json" ]
  match_cmd="$(jq -r '.deny[-1].match.command' "$USER_ROOT/.claude/passthru.json")"
  [ "$match_cmd" = "^curl " ]
}

@test "overlay: cancel verdict -> permissionDecision:ask (native fallback)" {
  setup_overlay_stub "cancel"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"ls"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "overlay: launch failure (exit 1) -> stderr log + native ask fallback" {
  # Stub exits 1 without writing a result file. Hook warns + emits
  # permissionDecision:"ask".
  setup_overlay_stub "ignored" 1
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"ls"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlay.sh exited"* ]]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

# Ask-rule path routed through overlay --------------------------------------

@test "overlay: ask rule + overlay available + yes_once -> allow overrides ask" {
  # A Task 6 ask-rule match used to emit permissionDecision:"ask". In Task
  # 8, ask-rule matches are routed through the overlay. When the user
  # approves via the overlay, the call is allowed outright.
  setup_overlay_stub "yes_once"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "confirm gh" }
  ]
}
EOF
  ti='{"command":"gh pr list"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "overlay: ask rule + overlay disabled -> permissionDecision:ask (Task 6 parity)" {
  # When the overlay is turned off, an ask rule resurfaces the Task 6
  # emit path: permissionDecision:"ask" with reason "passthru ask: <...>".
  setup_overlay_refuses_invocation
  touch "$USER_ROOT/.claude/passthru.overlay.disabled"
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "confirm gh" }
  ]
}
EOF
  ti='{"command":"gh pr list"}'
  payload="$(make_mode_payload 'Bash' "$ti" 'default' "$PROJ_ROOT")"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [ "$reason" = "passthru ask: confirm gh" ]
  [ ! -e "$TMP/overlay-stub-RAN" ]
}

# Audit attribution ---------------------------------------------------------

@test "audit: overlay-driven allow logs source=overlay" {
  enable_audit
  setup_overlay_stub "yes_once"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"gh api /repos/a/b"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVL"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "overlay" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tOVL" ]
}

@test "audit: overlay-driven deny logs source=overlay" {
  enable_audit
  setup_overlay_stub "no_once"
  export TMUX="mock/0"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/tmux"
  export PATH="$BIN:$PATH"

  ti='{"command":"curl evil.example"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tDEN"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "deny" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "overlay" ]
}

@test "audit: bypassPermissions mode logs source=overlay (no mode auto-allow)" {
  # Mode-based auto-allow is removed. bypassPermissions goes through the
  # overlay like every other mode and is logged with source=overlay.
  enable_audit
  setup_overlay_stub "yes_once"
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'bypassPermissions' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tMODE"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.source' <<<"$line"
  [ "$output" = "overlay" ]
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
}

# Breadcrumb on ask-emit paths ---------------------------------------------
# Every ask-emit path in the hook must drop a breadcrumb in $TMPDIR so the
# PostToolUse handler can classify the native-dialog outcome. Pre-fix these
# paths no-op'd and docs/rule-format.md:169 promised classification the hook
# was not delivering. Each test asserts the breadcrumb file exists after the
# hook returns.

@test "breadcrumb: overlay-disabled ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_refuses_invocation
  touch "$USER_ROOT/.claude/passthru.overlay.disabled"
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVD"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVD.json" ]
}

@test "breadcrumb: overlay-unavailable ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_refuses_invocation
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVU"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVU.json" ]
}

@test "breadcrumb: overlay-launch-failure ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_stub "ignored" 1
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVL"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVL.json" ]
}

@test "breadcrumb: overlay-cancel ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_stub "cancel"
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVC"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVC.json" ]
}

@test "breadcrumb: overlay unknown verdict ask path drops a breadcrumb" {
  enable_audit
  # Stub writes a verdict we do not recognize so the *) branch fires.
  setup_overlay_stub "banana"
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVK"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVK.json" ]
}

@test "breadcrumb: overlay-script-missing ask path drops a breadcrumb" {
  # Covers the (!-f OVERLAY_SH) branch. Build a stub plugin root (same as the
  # other overlay tests) then delete the overlay.sh so the handler hits the
  # missing-script fallback instead of running the stub. Multiplexer env is
  # still arranged by setup_overlay_stub so overlay_available returns true.
  enable_audit
  setup_overlay_stub "ignored"
  rm -f "$CLAUDE_PLUGIN_ROOT/scripts/overlay.sh"
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVM"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  # Stderr warning confirms we went through the missing-script branch.
  [[ "$output" == *"overlay script not found"* ]]
  # Breadcrumb must exist for PostToolUse classification coverage parity.
  [ -f "$TMPDIR/passthru-pre-tOVM.json" ]
  # Audit line carries the "overlay script missing" tag (no ask rule matched).
  line="$(head -n1 "$(audit_log)")"
  [ "$(jq -r '.event' <<<"$line")" = "ask" ]
  [ "$(jq -r '.reason' <<<"$line")" = "overlay script missing" ]
  [ "$(jq -r '.rule_index' <<<"$line")" = "null" ]
  [ "$(jq -r '.pattern' <<<"$line")" = "null" ]
}

@test "unknown verdict: ask-rule match preserves rule metadata in audit line" {
  # Regression pin for the emit_ask_fallback helper. When MATCHED=ask, every
  # fallback branch (including the unknown-verdict *) branch) must log the
  # matched rule's reason / rule_index / pattern, not a generic diagnostic
  # tag. Before the helper, the *) branch hardcoded "overlay unknown verdict"
  # and dropped the rule metadata.
  enable_audit
  # Plant a user-scope ask rule the payload will match.
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
  # Stub writes a verdict we do not recognize so the *) branch fires.
  setup_overlay_stub "banana"
  ti='{"command":"gh api /repos/a/b"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tUVASK"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  # Audit line must carry the rule's reason and a concrete (non-null) rule_index
  # and pattern, NOT the "overlay unknown verdict" tag.
  line="$(head -n1 "$(audit_log)")"
  [ "$(jq -r '.event' <<<"$line")" = "ask" ]
  [ "$(jq -r '.reason' <<<"$line")" = "confirm gh" ]
  [ "$(jq -r '.rule_index | type' <<<"$line")" = "number" ]
  pat="$(jq -r '.pattern' <<<"$line")"
  [ "$pat" != "null" ]
  [ -n "$pat" ]
  # And of course the breadcrumb still drops so PostToolUse can classify.
  [ -f "$TMPDIR/passthru-pre-tUVASK.json" ]
}

@test "chain: overlay-cancel + PostToolUse success -> asked_allowed_once" {
  # Full round-trip. Pre-tool-use emits ask and drops a breadcrumb. Post-tool-use
  # reads the crumb + tool_response and classifies the outcome. A successful
  # tool_response (no denial error string) with an unchanged settings.json
  # sha maps to asked_allowed_once via classify_passthrough_outcome.
  enable_audit
  setup_overlay_stub "cancel"
  ti='{"command":"ls"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tCHAIN"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  # Breadcrumb must exist for PostToolUse to do anything.
  [ -f "$TMPDIR/passthru-pre-tCHAIN.json" ]

  # Replay the post-tool-use handler with a success response. Use the stub
  # plugin root so post-tool-use.sh finds its sibling common.sh.
  post_payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg tr '{"stdout":"ok"}' \
    '{tool_name:$t,tool_input:$ti,tool_use_id:"tCHAIN",tool_response:($tr | fromjson)}')"
  post_handler="$CLAUDE_PLUGIN_ROOT/hooks/handlers/post-tool-use.sh"
  run bash -c "printf '%s' \"\$1\" | bash '$post_handler'" _ "$post_payload"
  [ "$status" -eq 0 ]
  # Audit log must now contain a post-tool-use line after the pre-tool-use line.
  [ -f "$(audit_log)" ]
  # Find the asked_allowed_once event on any line (allow=last write, ask=first).
  grep -q 'asked_allowed_once' "$(audit_log)"
  # Breadcrumb must be unlinked after PostToolUse consumed it.
  [ ! -f "$TMPDIR/passthru-pre-tCHAIN.json" ]
}
