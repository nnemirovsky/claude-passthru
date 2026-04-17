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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build"}}'
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
  # Use a non-readonly command with an explicit allow rule so the readonly
  # auto-allow step does not intercept before the rule-match path.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    { "tool": "Bash", "match": { "command": "^make(\\s|$)" }, "reason": "build tool" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build"}}'
  [ "$status" -eq 0 ]
  out="$output"
  event="$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
  [ "$event" = "PreToolUse" ]
  [ "$decision" = "allow" ]
  [ "$reason" = "passthru allow: build tool" ]
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
  # Use a non-readonly command with an explicit allow rule so the readonly
  # auto-allow step does not intercept before the rule-match audit path.
  enable_audit
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    { "tool": "Bash", "match": { "command": "^make(\\s|$)" }, "reason": "build tool" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build"},"tool_use_id":"t1"}'
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
  [ "$output" = "build tool" ]
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
  # Use a non-readonly command with a custom rule to avoid the readonly
  # auto-allow path intercepting before the rule-match audit path.
  enable_audit
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 1,
  "allow": [
    { "tool": "Bash", "match": { "command": "^make(\\s|$)" }, "reason": "allow make" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build"},"tool_use_id":"schema-allow"}'
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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{"version":1,"allow":[{"tool":"Bash","match":{"command":"[unclosed"}}],"deny":[]}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build"}}'
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
    local scope_literal=""
    if [ -n "$rule_json" ]; then
      rule_literal="printf '%s\\n' '$rule_json' >> \"\$PASSTHRU_OVERLAY_RESULT_FILE\""
      scope_literal="printf '%s\\n' 'project' >> \"\$PASSTHRU_OVERLAY_RESULT_FILE\""
    fi
    cat > "$stub_overlay" <<STUB
#!/usr/bin/env bash
: "\${PASSTHRU_OVERLAY_RESULT_FILE:?}"
mkdir -p "\$(dirname "\$PASSTHRU_OVERLAY_RESULT_FILE")" 2>/dev/null || true
printf '%s\\n' '${verdict}' > "\$PASSTHRU_OVERLAY_RESULT_FILE"
${rule_literal}
${scope_literal}
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

@test "mode: acceptEdits + Write OUTSIDE cwd -> native dialog (diff rendering)" {
  # Write outside cwd is not mode-auto-allowed. Write tools fall through to
  # CC's native dialog (permissionDecision: ask) for diff rendering instead
  # of the overlay.
  ti='{"file_path":"/tmp/elsewhere/foo.ts","content":"x"}'
  payload="$(make_mode_payload 'Write' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "mode: acceptEdits + Read inside cwd -> mode auto-allow (superset of default)" {
  # acceptEdits is a superset of default: it auto-allows everything default
  # does (Read/Grep/Glob inside cwd) PLUS edit tools inside cwd.
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/foo.ts" '{file_path:$fp}')"
  payload="$(make_mode_payload 'Read' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"mode-allow"* ]]
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

@test "mode: plan + Write -> native dialog (diff rendering)" {
  # plan mode restricts writes. Write tools fall through to native dialog
  # for diff rendering rather than the overlay.
  ti="$(jq -cn --arg fp "$PROJ_ROOT/src/foo.ts" '{file_path:$fp,content:"x"}')"
  payload="$(make_mode_payload 'Write' "$ti" 'plan' "$PROJ_ROOT")"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
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

@test "mode: default + WebSearch -> explicit allow (internal tool)" {
  ti='{"query":"what is claude code"}'
  payload="$(make_mode_payload 'WebSearch' "$ti" 'default' "$PROJ_ROOT")"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"passthru internal"* ]]
}

# Path-traversal safety ------------------------------------------------------

@test "mode: acceptEdits + file_path with ../ traversal -> native dialog (not auto-allowed)" {
  # Write with ../ traversal is not mode-auto-allowed. Write tools fall
  # through to native dialog for diff rendering.
  ti="$(jq -cn --arg fp "$PROJ_ROOT/../outside/secret.txt" '{file_path:$fp,content:"x"}')"
  payload="$(make_mode_payload 'Write' "$ti" 'acceptEdits' "$PROJ_ROOT")"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
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
  # Use a non-readonly command (make) so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  setup_overlay_refuses_invocation
  ti='{"command":"make build"}'
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

@test "overlay: yes_always verdict writes rule to project/allow AND emits allow" {
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
  # Rule landed in project-scope passthru.json under allow[] (default scope).
  [ -f "$PROJ_ROOT/.claude/passthru.json" ]
  match_cmd="$(jq -r '.allow[-1].match.command' "$PROJ_ROOT/.claude/passthru.json")"
  [ "$match_cmd" = "^gh " ]
  tool_val="$(jq -r '.allow[-1].tool' "$PROJ_ROOT/.claude/passthru.json")"
  [ "$tool_val" = "Bash" ]
}

@test "overlay: no_always verdict writes rule to project/deny AND emits deny" {
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
  [ -f "$PROJ_ROOT/.claude/passthru.json" ]
  match_cmd="$(jq -r '.deny[-1].match.command' "$PROJ_ROOT/.claude/passthru.json")"
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

  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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

  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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

@test "audit: bypassPermissions mode logs source=passthru-mode (mode auto-allow)" {
  # bypassPermissions auto-allows everything. Passthru emits allow with
  # source=passthru-mode, keeping the decision on our side.
  # Use a non-readonly command so the readonly auto-allow step does not intercept
  # before the mode-based auto-allow step.
  enable_audit
  ti='{"command":"make build"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'bypassPermissions' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tMODE"}')"
  run_handler "$payload"
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru-mode" ]
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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVD"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVD.json" ]
}

@test "breadcrumb: overlay-unavailable ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_refuses_invocation
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVU"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVU.json" ]
}

@test "breadcrumb: overlay-launch-failure ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_stub "ignored" 1
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
  payload="$(jq -cn --arg t 'Bash' --argjson ti "$ti" --arg m 'default' --arg c "$PROJ_ROOT" \
    '{tool_name:$t,tool_input:$ti,permission_mode:$m,cwd:$c,tool_use_id:"tOVL"}')"
  run_handler_in_stub_root "$payload"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/passthru-pre-tOVL.json" ]
}

@test "breadcrumb: overlay-cancel ask path drops a breadcrumb" {
  enable_audit
  setup_overlay_stub "cancel"
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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
  # Use a non-readonly command so the readonly auto-allow step does not intercept.
  ti='{"command":"make build"}'
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

# ===========================================================================
# Task 2: Compound command splitting integration
# ===========================================================================

@test "compound: deny rule on second segment blocks compound command" {
  # `echo hello && rm -rf /` must be denied because the deny rule on ^rm
  # matches the second segment, even though the first segment is benign.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^echo(\\s|$)" }, "reason": "allow echo" }
  ],
  "deny": [
    { "tool": "Bash", "match": { "command": "^rm " }, "reason": "no rm" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"echo hello && rm -rf /"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "deny" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"no rm"* ]]
}

@test "compound: allow rule on first segment only does NOT allow compound command" {
  # `ls -la && curl evil.example` should NOT be allowed because only the
  # first segment matches an allow rule. The second segment has no match,
  # so it falls through to overlay/native dialog.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^ls(\\s|$)" }, "reason": "allow ls" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la && curl evil.example"}}'
  [ "$status" -eq 0 ]
  # Should fall through to overlay path. With no multiplexer, gets ask fallback.
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "compound: allow rules covering ALL segments allows compound command" {
  # Two different rules covering two different segments: both must match
  # for the compound command to be allowed. Use non-readonly commands (make,
  # npm) so the readonly auto-allow step does not intercept.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^make(\\s|$)" }, "reason": "allow make" },
    { "tool": "Bash", "match": { "command": "^npm(\\s|$)" }, "reason": "allow npm" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build && npm test"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  # First segment's rule is used for audit. The first segment is "make build"
  # which matches the "allow make" rule.
  [[ "$reason" == *"allow make"* ]]
}

@test "compound: ask rule on any segment triggers ask for compound" {
  # `ls -la && gh pr list` with an ask rule on ^gh should trigger ask
  # for the whole compound command, even though the first segment matches
  # an allow rule.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^ls(\\s|$)" }, "reason": "allow ls" }
  ],
  "ask": [
    { "tool": "Bash", "match": { "command": "^gh " }, "reason": "confirm gh" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la && gh pr list"}}'
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"confirm gh"* ]]
}

@test "compound: one segment matches allow, another has no match -> falls through to overlay" {
  # `cat file.txt | some-unknown-cmd` where only cat has an allow rule.
  # The second segment has no match, so the whole command falls through.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^cat(\\s|$)" }, "reason": "allow cat" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"cat file.txt | some-unknown-cmd"}}'
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "compound: single command (no operators) works identically to current behavior" {
  # A single command without operators should use the existing single-match
  # loop, producing the same result as before. Use a non-readonly command
  # so the readonly auto-allow step does not intercept.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^make(\\s|$)" }, "reason": "allow make" }
  ],
  "deny": []
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"make build"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"allow make"* ]]
}

@test "compound: single-segment command denied through non-compound path" {
  # A single command without operators goes through the original single-match
  # path (the else branch at BASH_SEGMENT_COUNT <= 1). Verify deny still works
  # correctly on this path after compound splitting was introduced.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [
    { "tool": "Bash", "match": { "command": "^rm " }, "reason": "no rm" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/data"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "deny" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"no rm"* ]]
}

@test "compound: deny on piped segment blocks whole pipe chain" {
  # `echo ok | rm -rf /` must be denied because rm matches a deny rule.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^echo(\\s|$)" }, "reason": "allow echo" }
  ],
  "deny": [
    { "tool": "Bash", "match": { "command": "^rm " }, "reason": "no rm" }
  ]
}
EOF
  run_handler '{"tool_name":"Bash","tool_input":{"command":"echo ok | rm -rf /"}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "deny" ]
}

@test "compound: non-Bash tool ignores splitting (no behavior change)" {
  # WebFetch should not be affected by splitting logic at all.
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [
    { "tool": "WebFetch", "match": { "url": "^https://example\\.com" }, "reason": "allow example" }
  ],
  "deny": []
}
EOF
  payload='{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/api"}}'
  run_handler "$payload"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
}

# ===========================================================================
# Task 3: Read-only Bash command auto-allow
# ===========================================================================

@test "readonly: cat src/main.rs auto-allowed (relative path, inside cwd)" {
  run_handler "$(jq -cn --arg c "cat src/main.rs" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
  [[ "$reason" == *"cat"* ]]
}

@test "readonly: cat /proj/src/main.rs auto-allowed when cwd is /proj" {
  run_handler "$(jq -cn --arg c "cat $PROJ_ROOT/src/main.rs" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: cat /etc/passwd NOT auto-allowed (absolute path outside cwd)" {
  run_handler "$(jq -cn '{tool_name:"Bash",tool_input:{command:"cat /etc/passwd"},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  # Should fall through to overlay path (no readonly auto-allow).
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat with path traversal NOT auto-allowed" {
  # cat /proj/../etc/passwd uses /../ traversal to escape cwd. The
  # readonly_paths_allowed helper delegates to _pm_path_inside_cwd which
  # rejects paths containing /../. This must NOT be auto-allowed.
  run_handler "$(jq -cn --arg c "cat $PROJ_ROOT/../etc/passwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: head -n 10 file.txt auto-allowed (relative path)" {
  run_handler "$(jq -cn --arg c "head -n 10 file.txt" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: ls /proj/docs/ auto-allowed when cwd is /proj" {
  run_handler "$(jq -cn --arg c "ls $PROJ_ROOT/docs/" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: ls /tmp/random NOT auto-allowed (outside cwd)" {
  run_handler "$(jq -cn '{tool_name:"Bash",tool_input:{command:"ls /tmp/random"},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat file.txt | head auto-allowed (both segments readonly, relative paths)" {
  run_handler "$(jq -cn --arg c "cat file.txt | head" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: cat file.txt | rm -rf / NOT auto-allowed (rm is not readonly)" {
  run_handler "$(jq -cn --arg c "cat file.txt | rm -rf /" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  # rm is not readonly. Since rm -rf / matches no allow rule either, falls
  # through to overlay. But there is also no deny rule in this test, so
  # the outcome depends on whether the deny check catches rm. Without an
  # explicit deny rule, it falls to overlay.
  [ "$decision" = "ask" ]
}

@test "readonly: deny rule overrides readonly auto-allow" {
  # Even though cat is a readonly command, an explicit deny rule on ^cat
  # takes priority (deny runs before readonly check).
  cat > "$USER_ROOT/.claude/passthru.json" <<'EOF'
{
  "version": 2,
  "allow": [],
  "deny": [
    { "tool": "Bash", "match": { "command": "^cat " }, "reason": "no cat" }
  ]
}
EOF
  run_handler "$(jq -cn --arg c "cat src/file.txt" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "deny" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"no cat"* ]]
}

@test "readonly: echo safe string auto-allowed" {
  run_handler "$(jq -cn --arg c 'echo safe string' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: echo with dollar-paren NOT auto-allowed" {
  # echo $(dangerous) contains $() which the safety regex rejects.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"echo $(dangerous)"},"cwd":"'"$PROJ_ROOT"'"}'
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: echo with dollar-sign variable NOT auto-allowed" {
  # echo $HOME exposes environment variables via shell expansion.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"echo $HOME"},"cwd":"'"$PROJ_ROOT"'"}'
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: docker ps matches docker ps regex" {
  run_handler "$(jq -cn --arg c "docker ps" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$json_line")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: docker exec does NOT match docker ps regex" {
  run_handler "$(jq -cn --arg c "docker exec -it mycontainer bash" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  # docker exec is not a readonly command, falls through to overlay.
  [ "$decision" = "ask" ]
}

@test "readonly: find -fprint NOT auto-allowed (writes to file)" {
  run_handler "$(jq -cn --arg c 'find . -fprint out.txt' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: find -fprintf NOT auto-allowed (writes to file)" {
  run_handler "$(jq -cn --arg c 'find . -fprintf out.txt %p' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: find -fls NOT auto-allowed (writes to file)" {
  run_handler "$(jq -cn --arg c 'find . -fls out.txt' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: find -name still auto-allowed (benign predicate)" {
  run_handler "$(jq -cn --arg c 'find . -name *.txt' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "allow" ]
}

@test "readonly: allowed_dirs integration - _pm_path_inside_any_allowed with extra dir" {
  # Unit test for the allowed_dirs path-checking function. Task 6 will wire
  # this into the hook via load_allowed_dirs; this test verifies the function
  # itself works correctly with an allowed_dirs JSON array.
  source "$REPO_ROOT/hooks/common.sh"
  local cwd="/home/user/project"
  local allowed='["/opt/extra","/data/shared"]'
  # Path inside cwd: allowed.
  _pm_path_inside_any_allowed "/home/user/project/src/main.rs" "$cwd" "$allowed"
  # Path inside an extra allowed dir: allowed.
  _pm_path_inside_any_allowed "/opt/extra/config.json" "$cwd" "$allowed"
  _pm_path_inside_any_allowed "/data/shared/docs/readme.md" "$cwd" "$allowed"
  # Path outside all: not allowed.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; _pm_path_inside_any_allowed '/etc/passwd' '/home/user/project' '[\"$PROJ_ROOT\"]'"
  [ "$status" -ne 0 ]
}

@test "readonly: _pm_path_inside_cwd matches path equal to cwd itself" {
  source "$REPO_ROOT/hooks/common.sh"
  # Exact match: path IS the directory.
  _pm_path_inside_cwd "/home/user/project" "/home/user/project"
  # Descendant still works.
  _pm_path_inside_cwd "/home/user/project/sub/file" "/home/user/project"
  # Different path still rejected.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; _pm_path_inside_cwd '/etc/passwd' '/home/user/project'"
  [ "$status" -ne 0 ]
}

@test "readonly: _pm_path_inside_cwd handles trailing slash on directory" {
  source "$REPO_ROOT/hooks/common.sh"
  # Trailing slash on the directory must not break descendant matching.
  _pm_path_inside_cwd "/opt/shared/file.txt" "/opt/shared/"
  # Exact match with trailing slash also works.
  _pm_path_inside_cwd "/opt/shared" "/opt/shared/"
  # Unrelated path still rejected.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; _pm_path_inside_cwd '/etc/passwd' '/opt/shared/'"
  [ "$status" -ne 0 ]
}

@test "readonly: _pm_path_inside_any_allowed with trailing-slash allowed_dirs entry" {
  source "$REPO_ROOT/hooks/common.sh"
  local cwd="/home/user/project"
  local allowed='["/opt/shared/"]'
  # Path inside allowed dir with trailing slash must still match.
  _pm_path_inside_any_allowed "/opt/shared/docs/readme.md" "$cwd" "$allowed"
  # Exact match of the dir itself.
  _pm_path_inside_any_allowed "/opt/shared" "$cwd" "$allowed"
}

@test "readonly: allowed_dirs integration - readonly_paths_allowed with extra dir" {
  # Unit test: readonly_paths_allowed should accept paths in allowed dirs.
  source "$REPO_ROOT/hooks/common.sh"
  local cwd="$PROJ_ROOT"
  local allowed="[\"$TMP/extra\"]"
  # cat with a path in the allowed dir should pass.
  readonly_paths_allowed "cat $TMP/extra/file.txt" "$cwd" "$allowed"
  # cat with a path outside all dirs should fail.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'cat /etc/passwd' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
}

@test "readonly: readonly_paths_allowed rejects tilde paths" {
  # Unit test: tilde-prefixed paths must be rejected because Bash expands
  # ~ to $HOME before execution. Without this check, ~/.ssh/id_rsa would
  # be treated as a relative path inside cwd.
  source "$REPO_ROOT/hooks/common.sh"
  # ~/... must be rejected.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'cat ~/.ssh/id_rsa' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
  # Bare ~ must be rejected.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'ls ~' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
  # Normal relative path still allowed (treated as inside cwd).
  readonly_paths_allowed "cat src/main.rs" "$PROJ_ROOT" "[]"
}

@test "readonly: readonly_paths_allowed rejects ~user, ~+, ~- expansions" {
  # Bash expands ~root to the root user home dir, ~+ to $PWD, ~- to $OLDPWD.
  # All tilde-prefixed tokens must be rejected, not just ~ and ~/.
  source "$REPO_ROOT/hooks/common.sh"
  # ~root -> /var/root (or similar).
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'cat ~root/.ssh/id_rsa' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
  # ~+ -> $PWD.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'cat ~+/file' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
  # ~- -> $OLDPWD.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'cat ~-/file' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
  # ~nobody -> another user home.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'ls ~nobody' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
}

@test "readonly: readonly_paths_allowed rejects bare .. traversal" {
  # A bare ".." token (without trailing /) escapes cwd just like ../path.
  source "$REPO_ROOT/hooks/common.sh"
  # ls .. lists the parent directory.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'ls ..' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
  # find .. -name secret searches the parent tree.
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'find .. -name secret' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
}

@test "readonly: readonly_paths_allowed rejects quoted multi-word traversal paths" {
  # read -ra splits on whitespace, breaking a quoted multi-word path like
  # "../secret dir/file" into tokens with orphaned quotes. The leading-only
  # quote strip must expose the ../ pattern for the traversal guard.
  source "$REPO_ROOT/hooks/common.sh"
  run bash -c "source '$REPO_ROOT/hooks/common.sh'; readonly_paths_allowed 'cat \"../secret dir/file\"' '$PROJ_ROOT' '[]'"
  [ "$status" -ne 0 ]
}

@test "readonly: audit log records passthru-readonly source" {
  enable_audit
  run_handler "$(jq -cn --arg c "cat src/file.txt" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'",tool_use_id:"tRO"}')"
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru-readonly" ]
  run jq -r '.reason' <<<"$line"
  [[ "$output" == *"readonly"* ]]
  [[ "$output" == *"cat"* ]]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tRO" ]
}

# ===========================================================================
# Task 4: Auto-allow Agent, Skill, and Glob tools
# ===========================================================================

@test "internal-allow: Agent tool returns explicit allow decision (not passthrough)" {
  run_handler '{"tool_name":"Agent","tool_input":{}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$reason" = "passthru internal: Agent" ]
  # Must NOT be a passthrough ({"continue":true}).
  run jq -e '.continue' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "internal-allow: Skill tool returns explicit allow decision (not passthrough)" {
  run_handler '{"tool_name":"Skill","tool_input":{}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$reason" = "passthru internal: Skill" ]
  # Must NOT be a passthrough.
  run jq -e '.continue' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "internal-allow: Glob tool returns explicit allow decision (not passthrough)" {
  run_handler '{"tool_name":"Glob","tool_input":{}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$reason" = "passthru internal: Glob" ]
  # Must NOT be a passthrough.
  run jq -e '.continue' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "internal-allow: ToolSearch still returns passthrough (not allow)" {
  run_handler '{"tool_name":"ToolSearch","tool_input":{}}'
  [ "$status" -eq 0 ]
  run jq -r '.continue' <<<"$output"
  [ "$output" = "true" ]
  # Must NOT have hookSpecificOutput (not an explicit allow).
  run jq -e '.hookSpecificOutput' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "internal-allow: TaskCreate still returns passthrough (not allow)" {
  run_handler '{"tool_name":"TaskCreate","tool_input":{}}'
  [ "$status" -eq 0 ]
  run jq -r '.continue' <<<"$output"
  [ "$output" = "true" ]
  # Must NOT have hookSpecificOutput (not an explicit allow).
  run jq -e '.hookSpecificOutput' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "internal-allow: Agent audit logged with source passthru-internal" {
  enable_audit
  run_handler '{"tool_name":"Agent","tool_input":{},"tool_use_id":"tAgent"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru-internal" ]
  run jq -r '.reason' <<<"$line"
  [ "$output" = "passthru internal: Agent" ]
  run jq -r '.tool' <<<"$line"
  [ "$output" = "Agent" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tAgent" ]
}

@test "internal-allow: Skill audit logged with source passthru-internal" {
  enable_audit
  run_handler '{"tool_name":"Skill","tool_input":{},"tool_use_id":"tSkill"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru-internal" ]
  run jq -r '.reason' <<<"$line"
  [ "$output" = "passthru internal: Skill" ]
  run jq -r '.tool' <<<"$line"
  [ "$output" = "Skill" ]
}

@test "internal-allow: Glob audit logged with source passthru-internal" {
  enable_audit
  run_handler '{"tool_name":"Glob","tool_input":{},"tool_use_id":"tGlob"}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "allow" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "passthru-internal" ]
  run jq -r '.reason' <<<"$line"
  [ "$output" = "passthru internal: Glob" ]
  run jq -r '.tool' <<<"$line"
  [ "$output" = "Glob" ]
}

@test "internal-allow: Agent bypasses rule loading (works even with broken rules)" {
  # Write invalid JSON to the rule file. Rule loading would fail.
  printf 'NOT VALID JSON' > "$USER_ROOT/.claude/passthru.json"
  run_handler '{"tool_name":"Agent","tool_input":{}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
}

# ===========================================================================
# Task 6: Additional allowed directories
# ===========================================================================

@test "allowed-dirs: Read tool auto-allowed for file in additional allowed dir" {
  # Create a passthru.json with allowed_dirs pointing to an extra dir.
  cat > "$USER_ROOT/.claude/passthru.json" <<EOF
{
  "version": 2,
  "allowed_dirs": ["$TMP/extra"],
  "allow": [],
  "deny": [],
  "ask": []
}
EOF
  run_handler "$(jq -cn --arg fp "$TMP/extra/data.txt" '{tool_name:"Read",tool_input:{file_path:$fp},cwd:"'"$PROJ_ROOT"'",permission_mode:"default"}')"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"mode-allow"* ]]
}

@test "allowed-dirs: Write tool auto-allowed in acceptEdits mode for file in allowed dir" {
  cat > "$USER_ROOT/.claude/passthru.json" <<EOF
{
  "version": 2,
  "allowed_dirs": ["$TMP/extra"],
  "allow": [],
  "deny": [],
  "ask": []
}
EOF
  run_handler "$(jq -cn --arg fp "$TMP/extra/output.txt" '{tool_name:"Write",tool_input:{file_path:$fp},cwd:"'"$PROJ_ROOT"'",permission_mode:"acceptEdits"}')"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"mode-allow"* ]]
}

@test "allowed-dirs: Grep tool auto-allowed for path in additional allowed dir" {
  cat > "$USER_ROOT/.claude/passthru.json" <<EOF
{
  "version": 2,
  "allowed_dirs": ["$TMP/extra"],
  "allow": [],
  "deny": [],
  "ask": []
}
EOF
  run_handler "$(jq -cn --arg p "$TMP/extra/src" '{tool_name:"Grep",tool_input:{path:$p},cwd:"'"$PROJ_ROOT"'",permission_mode:"default"}')"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
}

@test "allowed-dirs: file outside all allowed dirs falls through to overlay" {
  cat > "$USER_ROOT/.claude/passthru.json" <<EOF
{
  "version": 2,
  "allowed_dirs": ["$TMP/extra"],
  "allow": [],
  "deny": [],
  "ask": []
}
EOF
  # /etc/passwd is outside cwd and outside allowed_dirs.
  run_handler '{"tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"cwd":"'"$PROJ_ROOT"'","permission_mode":"default"}'
  [ "$status" -eq 0 ]
  # Should NOT be an allow decision (should fall through to overlay/ask).
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "allowed-dirs: readonly auto-allow uses allowed dirs for path validation" {
  cat > "$USER_ROOT/.claude/passthru.json" <<EOF
{
  "version": 2,
  "allowed_dirs": ["$TMP/extra"],
  "allow": [],
  "deny": [],
  "ask": []
}
EOF
  # cat with absolute path in allowed dir should be auto-allowed by readonly.
  run_handler "$(jq -cn --arg c "cat $TMP/extra/file.txt" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [[ "$reason" == *"readonly"* ]]
}

@test "readonly: cat file > /tmp/out NOT auto-allowed (output redirect bypass)" {
  # split_bash_command strips redirections, leaving `cat file` which passes
  # is_readonly_command. But the original command writes to /tmp/out. The
  # has_output_redirect guard must catch this and skip readonly auto-allow.
  run_handler "$(jq -cn --arg c "cat file.txt > /tmp/out" '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: echo ok >> ~/.ssh/config NOT auto-allowed (append redirect bypass)" {
  # Append redirect >> is also an output redirect.
  run_handler "$(jq -cn --arg c 'echo ok >> ~/.ssh/config' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: echo with quoted > NOT auto-allowed (safety regex rejects >)" {
  # The quote-aware tokenizer correctly preserves the segment as
  # echo "hello > world", but the echo safety regex categorically
  # rejects > in its character class (even inside quotes). This is the
  # expected conservative behavior: the user gets an overlay prompt.
  run_handler "$(jq -cn --arg c 'echo "hello > world"' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat ../../../etc/passwd NOT auto-allowed (relative path traversal)" {
  # Relative paths with ../ can traverse outside cwd. readonly_paths_allowed
  # must reject tokens containing ../ patterns.
  run_handler "$(jq -cn --arg c 'cat ../../../etc/passwd' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat \"../secret\" NOT auto-allowed (quoted relative traversal)" {
  # Even with quotes around the path, ../ traversal should be caught.
  run_handler "$(jq -cn --arg c 'cat "../secret"' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat \"/etc/passwd\" NOT auto-allowed (quoted absolute path outside cwd)" {
  # Quoted absolute paths like "/etc/passwd" must be detected as absolute
  # after quote stripping. Without the fix, the leading " causes the token
  # to be treated as a relative path.
  run_handler "$(jq -cn --arg c 'cat "/etc/passwd"' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: ls .. NOT auto-allowed (bare dotdot traversal)" {
  # A bare ".." without trailing / still escapes cwd.
  run_handler "$(jq -cn --arg c 'ls ..' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat ~root/.ssh/id_rsa NOT auto-allowed (tilde user expansion)" {
  # ~root expands to the root user home dir. Must not be auto-allowed.
  run_handler "$(jq -cn --arg c 'cat ~root/.ssh/id_rsa' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat \"../secret dir/file\" NOT auto-allowed (quoted multi-word traversal)" {
  # Multi-word quoted path with traversal. Whitespace splitting breaks the
  # quotes but the orphaned-quote strip must still expose the traversal.
  run_handler "$(jq -cn --arg c 'cat "../secret dir/file"' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: wc < /etc/passwd NOT auto-allowed (input redirect bypass)" {
  # split_bash_command strips input redirections, leaving `wc` which passes
  # is_readonly_command. But CC executes the original command which reads
  # /etc/passwd via the redirect. The has_redirect guard must catch this.
  run_handler "$(jq -cn --arg c 'wc < /etc/passwd' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat ~/.ssh/id_rsa NOT auto-allowed (tilde expansion bypass)" {
  # Bash expands ~ to $HOME before execution. The token ~/.ssh/id_rsa does
  # not start with / so without the tilde guard it would be treated as a
  # relative path inside cwd.
  run_handler "$(jq -cn --arg c 'cat ~/.ssh/id_rsa' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: head ~/secrets.txt NOT auto-allowed (tilde home dir)" {
  run_handler "$(jq -cn --arg c 'head ~/secrets.txt' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "readonly: cat with herestring NOT auto-allowed (safety regex rejects <)" {
  # The quote-aware tokenizer correctly preserves the full segment as
  # cat <<< "hello". The cat safety regex rejects < in its character
  # class, so the segment fails is_readonly_command. This is the expected
  # conservative behavior. The old non-quote-aware stripper corrupted the
  # segment to just "cat" which then passed.
  run_handler "$(jq -cn --arg c 'cat <<< "hello"' '{tool_name:"Bash",tool_input:{command:$c},cwd:"'"$PROJ_ROOT"'"}')"
  [ "$status" -eq 0 ]
  json_line="$(printf '%s\n' "$output" | grep -o '{"hookSpecificOutput".*}' | head -n1)"
  [ -n "$json_line" ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$json_line")"
  [ "$decision" = "ask" ]
}

@test "internal-allow: Skill bypasses deny rules (checked before rule matching)" {
  # Place a deny rule that would match Skill by tool name regex.
  cat > "$USER_ROOT/.claude/passthru.json" <<'JSON'
{
  "version": 2,
  "deny": [{"tool": "^Skill$", "reason": "should not fire"}],
  "allow": [],
  "ask": []
}
JSON
  run_handler '{"tool_name":"Skill","tool_input":{}}'
  [ "$status" -eq 0 ]
  decision="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")"
  [ "$decision" = "allow" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  [ "$reason" = "passthru internal: Skill" ]
}
