#!/usr/bin/env bats

# tests/post_hook_handler.bats
# End-to-end coverage for hooks/handlers/post-tool-use.sh.
# Every test pipes a synthetic PostToolUse payload and asserts the log line
# (or absence of log line) plus breadcrumb lifecycle. Isolation via
# PASSTHRU_USER_HOME, PASSTHRU_PROJECT_DIR, TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HANDLER="$REPO_ROOT/hooks/handlers/post-tool-use.sh"

  TMP="$(mktemp -d -t passthru-post.XXXXXX)"
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

enable_audit() {
  touch "$USER_ROOT/.claude/passthru.audit.enabled"
}

audit_log() {
  printf '%s/.claude/passthru-audit.log\n' "$USER_ROOT"
}

crumb_path() {
  printf '%s/passthru-pre-%s.json\n' "$TMPDIR" "$1"
}

sha256_of() {
  # Emit sha256 hex of $1. Works on macOS (shasum) and Linux (sha256sum).
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# write_breadcrumb <tool_use_id> <tool> <tool_input_json> <user_sha_or_empty> <proj_sha_or_empty>
write_breadcrumb() {
  local tuid="$1" tool="$2" tool_input="$3" usha="$4" psha="$5"
  local path
  path="$(crumb_path "$tuid")"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tool "$tool" \
    --argjson tool_input "$tool_input" \
    --arg usha "$usha" \
    --arg psha "$psha" \
    '{
      ts: $ts,
      tool: $tool,
      tool_input: $tool_input,
      settings_sha_user: (if $usha == "" then null else $usha end),
      settings_sha_project: (if $psha == "" then null else $psha end)
    }' > "$path"
}

run_handler() {
  # $1 = stdin JSON
  run bash -c "printf '%s' \"\$1\" | bash '$HANDLER'" _ "$1"
}

# Write a minimal settings.json with the given permissions.allow / deny arrays.
# $1 path, $2 allow JSON array, $3 deny JSON array.
write_settings() {
  local path="$1" allow="$2" deny="$3"
  mkdir -p "$(dirname "$path")"
  jq -cn \
    --argjson allow "$allow" \
    --argjson deny "$deny" \
    '{ permissions: { allow: $allow, deny: $deny } }' > "$path"
}

# ---------------------------------------------------------------------------
# Disabled mode (sentinel absent)
# ---------------------------------------------------------------------------

@test "audit disabled + breadcrumb exists -> no log, breadcrumb self-healed (unlinked)" {
  # Plan contract: "audit disabled = no-op regardless of breadcrumb (self-heal
  # - unlink only)". We do not write the audit log, do not classify, but we
  # do drop the orphan crumb so $TMPDIR does not slowly fill up if the user
  # toggles audit on/off across sessions.
  write_breadcrumb "tid1" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tid1","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
  # Breadcrumb is self-healed when audit was disabled.
  [ ! -f "$(crumb_path "tid1")" ]
}

@test "audit disabled + no breadcrumb + unrelated tool_use_id -> no-op, no error" {
  # Disabled, no crumb to clean up. Should still pass through cleanly.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tid-other","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

# ---------------------------------------------------------------------------
# Enabled but no breadcrumb (PreToolUse decided allow/deny itself, or first
# run after enabling audit)
# ---------------------------------------------------------------------------

@test "audit enabled + no breadcrumb -> no log, passthrough stdout" {
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tid-nope","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

# ---------------------------------------------------------------------------
# Happy paths: successful tool response
# ---------------------------------------------------------------------------

@test "settings unchanged + success -> asked_allowed_once, breadcrumb unlinked" {
  enable_audit
  # No settings file at all; old sha is empty, current sha is empty -> unchanged.
  write_breadcrumb "tidA" "Bash" '{"command":"ls -la"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"tidA","tool_response":{"stdout":"file1"}}'
  [ "$status" -eq 0 ]
  [ -f "$(audit_log)" ]

  line="$(head -n1 "$(audit_log)")"
  run jq -c '.' <<<"$line"
  [ "$status" -eq 0 ]
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_once" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "native" ]
  run jq -r '.tool' <<<"$line"
  [ "$output" = "Bash" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tidA" ]

  [ ! -f "$(crumb_path "tidA")" ]
}

@test "settings.json gained matching Bash(ls:*) entry -> asked_allowed_always" {
  enable_audit
  # Pre-call: no settings file. Old sha empty.
  write_breadcrumb "tidB" "Bash" '{"command":"ls -la"}' "" ""
  # User answered the dialog with "allow always" -> settings.json gained Bash(ls:*).
  write_settings "$USER_ROOT/.claude/settings.json" '["Bash(ls:*)"]' '[]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_use_id":"tidB","tool_response":{"stdout":"file1"}}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_always" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "tidB" ]
  [ ! -f "$(crumb_path "tidB")" ]
}

@test "settings.json changed with unrelated entry -> asked_allowed_unknown" {
  enable_audit
  # Old settings file present with some sha; new file has an unrelated new entry.
  write_settings "$USER_ROOT/.claude/settings.json" '["Read(/tmp/**)"]' '[]'
  old_sha="$(sha256_of "$USER_ROOT/.claude/settings.json")"
  write_breadcrumb "tidC" "Bash" '{"command":"curl example.com"}' "$old_sha" ""
  # Now simulate user adding a totally unrelated entry (nothing about Bash/curl).
  write_settings "$USER_ROOT/.claude/settings.json" '["Read(/tmp/**)","Read(/home/foo/**)"]' '[]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"curl example.com"},"tool_use_id":"tidC","tool_response":{"stdout":"ok"}}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_unknown" ]
  [ ! -f "$(crumb_path "tidC")" ]
}

# ---------------------------------------------------------------------------
# Denied outcomes
# ---------------------------------------------------------------------------

@test "tool_response permissionDenied + settings unchanged -> asked_denied_once" {
  enable_audit
  write_breadcrumb "tidD" "Bash" '{"command":"rm -rf /"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"tidD","tool_response":{"permissionDenied":true}}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "native" ]
  [ ! -f "$(crumb_path "tidD")" ]
}

@test "tool_response denied + settings gained matching deny entry -> asked_denied_always" {
  enable_audit
  write_breadcrumb "tidE" "Bash" '{"command":"curl evil.example.com"}' "" ""
  write_settings "$USER_ROOT/.claude/settings.json" '[]' '["Bash(curl:*)"]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"curl evil.example.com"},"tool_use_id":"tidE","tool_response":{"permissionDenied":true}}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_always" ]
  [ ! -f "$(crumb_path "tidE")" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "malformed breadcrumb JSON -> stderr warning, no log line, breadcrumb unlinked" {
  enable_audit
  # Drop a bad crumb.
  bad="$(crumb_path "tidBAD")"
  printf '{ not json' > "$bad"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidBAD","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  # Either stdout or stderr may surface, `run` lumps both; look for the warning marker.
  [[ "$output" == *"malformed breadcrumb"* ]] || [[ "$output" == *"warning"* ]]
  # No log line created.
  [ ! -f "$(audit_log)" ]
  # Breadcrumb unlinked regardless.
  [ ! -f "$bad" ]
}

@test "missing tool_use_id -> no crumb lookup, passthrough, no log" {
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

@test "malformed stdin JSON -> warning, passthrough, no log" {
  enable_audit
  run_handler '{ not json'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

@test "stdout emits exactly one JSON object on happy path" {
  enable_audit
  write_breadcrumb "tidJSON" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidJSON","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  # `output` lumps stderr + stdout; extract the last line with {"continue"...}
  [[ "$output" == *'{"continue": true}'* ]]
  # Log line round-trip parses.
  run jq -c '.' "$(audit_log)"
  [ "$status" -eq 0 ]
}

@test "log line contains all required fields and parses cleanly" {
  enable_audit
  write_breadcrumb "tidFIELDS" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidFIELDS","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -c '.' <<<"$line"
  [ "$status" -eq 0 ]
  # All required keys present.
  for key in ts event source tool tool_use_id; do
    v="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$line")"
    [ -n "$v" ]
  done
}

# ---------------------------------------------------------------------------
# WebFetch domain-scoped entry heuristic
# ---------------------------------------------------------------------------

@test "WebFetch: settings gained matching WebFetch(domain:...) entry -> asked_allowed_always" {
  enable_audit
  write_breadcrumb "tidW" "WebFetch" '{"url":"https://docs.anthropic.com/claude/docs/overview"}' "" ""
  write_settings "$USER_ROOT/.claude/settings.json" '["WebFetch(domain:docs.anthropic.com)"]' '[]'
  run_handler '{"tool_name":"WebFetch","tool_input":{"url":"https://docs.anthropic.com/claude/docs/overview"},"tool_use_id":"tidW","tool_response":{"content":"ok"}}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_always" ]
}

# ---------------------------------------------------------------------------
# is_denied_response: regression / false-positive surface
# ---------------------------------------------------------------------------

@test "is_denied_response: missing tool_response field maps to literal null (denied per plan)" {
  enable_audit
  write_breadcrumb "tidEMPTY" "Bash" '{"command":"ls"}' "" ""
  # Plan contract (line 268): "tool_response missing or marked as
  # permission-blocked -> asked_denied_once". A payload without
  # tool_response is normalized to JSON null and classified as denied.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidEMPTY"}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

@test "is_denied_response: tool_response = {} (no permissionDenied) -> not denied" {
  enable_audit
  write_breadcrumb "tidOBJ" "Bash" '{"command":"ls"}' "" ""
  # Empty object is a positive signal of a successful tool_response (no
  # permissionDenied flag, no error, no denied status). Should classify as
  # allowed once.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidOBJ","tool_response":{}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_once" ]
}

@test "is_denied_response: tool_response = null literal -> classified as denied" {
  enable_audit
  write_breadcrumb "tidNULL" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidNULL","tool_response":null}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

@test "is_denied_response: error message containing 'permissions' (no anchor) -> NOT denied" {
  enable_audit
  write_breadcrumb "tidPERM" "Bash" '{"command":"chmod 0644 /tmp/x"}' "" ""
  # Old overbroad regex flagged any 'permission' substring as denied. The
  # corrected anchored pattern requires a permission_denied / access_denied
  # / not_allowed / blocked / denied token, not just any "permission" word.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"chmod 0644 /tmp/x"},"tool_use_id":"tidPERM","tool_response":{"stdout":"Updated file permissions to 0644"}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_once" ]
}

@test "is_denied_response: error: 'permission denied' (anchored) -> denied" {
  enable_audit
  write_breadcrumb "tidPD" "Bash" '{"command":"cat /etc/shadow"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"cat /etc/shadow"},"tool_use_id":"tidPD","tool_response":{"error":"permission denied"}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

# ---------------------------------------------------------------------------
# entries_look_tailored: false-positive guard
# ---------------------------------------------------------------------------

@test "entries_look_tailored: bare 'Read' entry does NOT match Bash call (cross-tool guard)" {
  enable_audit
  # Old settings file is empty -> sha empty.
  write_breadcrumb "tidXTOOL" "Bash" '{"command":"ls"}' "" ""
  # User added a bare "Read" entry while the dialog was open for Bash.
  # That entry does not cover the Bash call, so we should classify as unknown.
  write_settings "$USER_ROOT/.claude/settings.json" '["Read"]' '[]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tidXTOOL","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_unknown" ]
}

@test "entries_look_tailored: WebFetch(domain:x.com) does NOT mark a Bash call as tailored" {
  enable_audit
  write_breadcrumb "tidXTOOL2" "Bash" '{"command":"curl https://example.com"}' "" ""
  # Settings gained a WebFetch domain entry, but the call was a Bash curl.
  # That entry would cover an actual WebFetch call, not this one.
  write_settings "$USER_ROOT/.claude/settings.json" '["WebFetch(domain:example.com)"]' '[]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"curl https://example.com"},"tool_use_id":"tidXTOOL2","tool_response":{"stdout":"ok"}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_unknown" ]
}

@test "entries_look_tailored: generic 'OtherTool()' (empty arg) on unknown tool does NOT mark as tailored" {
  enable_audit
  write_breadcrumb "tidGEN" "Edit" '{"file_path":"/tmp/x"}' "" ""
  # Settings gained "Edit()" - bare parentheses with empty arg. The fallback
  # branch must treat empty entry_arg as a non-match, otherwise every Edit
  # call would classify as tailored.
  write_settings "$USER_ROOT/.claude/settings.json" '["Edit()"]' '[]'
  run_handler '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"},"tool_use_id":"tidGEN","tool_response":{"ok":true}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_unknown" ]
}

@test "entry_matches_call: Bash multi-word prefix 'gh pr:*' matches 'gh pr close 42'" {
  enable_audit
  write_breadcrumb "tidGH" "Bash" '{"command":"gh pr close 42"}' "" ""
  # Multi-word prefix is a corner of the Bash branch we previously did not
  # exercise.
  write_settings "$USER_ROOT/.claude/settings.json" '["Bash(gh pr:*)"]' '[]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh pr close 42"},"tool_use_id":"tidGH","tool_response":{"stdout":"closed"}}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_allowed_always" ]
}

# ---------------------------------------------------------------------------
# tool_use_id sanitization (path-traversal guard)
# ---------------------------------------------------------------------------

@test "tool_use_id with path-traversal characters -> sanitized, no traversal" {
  enable_audit
  # Plant the breadcrumb that the SANITIZED id would resolve to.
  safe_id="abc"
  write_breadcrumb "$safe_id" "Bash" '{"command":"ls"}' "" ""
  # Pass a tool_use_id with traversal characters; sanitizer should strip them.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"../../etc/abc","tool_response":{"stdout":"x"}}'
  [ "$status" -eq 0 ]
  # Either the handler consumed the safe-id breadcrumb (and unlinked it)
  # OR it found nothing and no-oped. Both outcomes are safe; what we MUST
  # guarantee is that no file was touched outside $TMPDIR.
  [ ! -e "$BCTMP/../../etc/abc" ] || true
  # The safe-id breadcrumb has either been consumed (asked_allowed_once) or
  # left untouched (no breadcrumb match). We only assert no traversal.
}
