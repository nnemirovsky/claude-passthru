#!/usr/bin/env bats

# tests/post_tool_use_failure_hook.bats
# End-to-end coverage for hooks/handlers/post-tool-use-failure.sh.
# Every test pipes a synthetic PostToolUseFailure payload and asserts the
# log line (or absence of log line) plus breadcrumb lifecycle. Isolation
# via PASSTHRU_USER_HOME, PASSTHRU_PROJECT_DIR, TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HANDLER="$REPO_ROOT/hooks/handlers/post-tool-use-failure.sh"

  TMP="$(mktemp -d -t passthru-postfail.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  BCTMP="$TMP/tmp"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude" "$BCTMP"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"
  export TMPDIR="$BCTMP"

  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
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
  passthru_sha256 "$1"
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

@test "audit disabled + breadcrumb exists -> no log, breadcrumb self-healed" {
  write_breadcrumb "ftid1" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"ftid1","error":"permission denied"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
  [ ! -f "$(crumb_path "ftid1")" ]
}

@test "audit disabled + no breadcrumb -> no-op, no error" {
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"ftid-none","error":"oops"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

# ---------------------------------------------------------------------------
# Enabled, no breadcrumb (failure happened for a call we did not passthrough)
# ---------------------------------------------------------------------------

@test "audit enabled + no breadcrumb -> no log, passthrough stdout" {
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"ftid-nope","error":"x"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

# ---------------------------------------------------------------------------
# Permission-denied classification (via error string)
# ---------------------------------------------------------------------------

@test "failure with 'permission denied' error + settings unchanged -> asked_denied_once" {
  enable_audit
  write_breadcrumb "ftidP1" "Bash" '{"command":"rm -rf /"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"tool_use_id":"ftidP1","error":"permission denied by user"}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "native" ]
  run jq -r '.tool_use_id' <<<"$line"
  [ "$output" = "ftidP1" ]
  [ ! -f "$(crumb_path "ftidP1")" ]
}

@test "failure with 'permission denied' + settings gained matching deny -> asked_denied_always" {
  enable_audit
  write_breadcrumb "ftidP2" "Bash" '{"command":"curl evil.example.com"}' "" ""
  write_settings "$USER_ROOT/.claude/settings.json" '[]' '["Bash(curl:*)"]'
  run_handler '{"tool_name":"Bash","tool_input":{"command":"curl evil.example.com"},"tool_use_id":"ftidP2","error":"permission denied"}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_always" ]
  [ ! -f "$(crumb_path "ftidP2")" ]
}

@test "failure with 'access_denied' (underscore) -> asked_denied_once" {
  enable_audit
  write_breadcrumb "ftidP3" "Bash" '{"command":"x"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":"ftidP3","error":"access_denied by policy"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

@test "failure with 'not allowed' error -> asked_denied_once" {
  enable_audit
  write_breadcrumb "ftidP4" "Bash" '{"command":"x"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":"ftidP4","error":"operation not allowed here"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

@test "failure with whole-word 'blocked' -> asked_denied_once" {
  enable_audit
  write_breadcrumb "ftidP5" "Bash" '{"command":"x"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":"ftidP5","error":"call was blocked"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

# ---------------------------------------------------------------------------
# Generic (non-permission) failure -> `errored` event with error_type
# ---------------------------------------------------------------------------

@test "failure with generic error + error_type -> errored event preserves error_type" {
  enable_audit
  write_breadcrumb "ftidE1" "Bash" '{"command":"gh api /nowhere"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"gh api /nowhere"},"tool_use_id":"ftidE1","error":"HTTP 404","error_type":"not_found"}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "errored" ]
  run jq -r '.tool' <<<"$line"
  [ "$output" = "Bash" ]
  run jq -r '.error_type' <<<"$line"
  [ "$output" = "not_found" ]
  run jq -r '.source' <<<"$line"
  [ "$output" = "native" ]
  [ ! -f "$(crumb_path "ftidE1")" ]
}

@test "failure with is_timeout=true and no error_type -> errored with synthesized 'timeout' type" {
  enable_audit
  write_breadcrumb "ftidE2" "Bash" '{"command":"sleep 1000"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"sleep 1000"},"tool_use_id":"ftidE2","error":"exceeded timeout","is_timeout":true}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "errored" ]
  run jq -r '.error_type' <<<"$line"
  [ "$output" = "timeout" ]
}

@test "failure with is_interrupt=true and no error_type -> errored with synthesized 'interrupted'" {
  enable_audit
  write_breadcrumb "ftidE3" "Bash" '{"command":"big build"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"big build"},"tool_use_id":"ftidE3","error":"user interrupted","is_interrupt":true}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "errored" ]
  run jq -r '.error_type' <<<"$line"
  [ "$output" = "interrupted" ]
}

@test "failure with no error_type and no interrupt/timeout flags -> errored with empty error_type omitted" {
  enable_audit
  write_breadcrumb "ftidE4" "Edit" '{"file_path":"/tmp/x"}' "" ""
  run_handler '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"},"tool_use_id":"ftidE4","error":"generic runtime failure"}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "errored" ]
  # error_type is omitted entirely when CC did not give us one and neither
  # the interrupt nor timeout flag is set.
  run jq -r 'has("error_type")' <<<"$line"
  [ "$output" = "false" ]
}

@test "permission-denied error beats error_type: permission wins over generic errored" {
  enable_audit
  write_breadcrumb "ftidPRI" "Bash" '{"command":"x"}' "" ""
  # Even if error_type is `generic`, an error string of "permission denied"
  # must route to the asked_denied_* path, not errored.
  run_handler '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_use_id":"ftidPRI","error":"permission denied","error_type":"generic"}'
  [ "$status" -eq 0 ]
  line="$(head -n1 "$(audit_log)")"
  run jq -r '.event' <<<"$line"
  [ "$output" = "asked_denied_once" ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "malformed breadcrumb JSON -> stderr warning, no log line, breadcrumb unlinked" {
  enable_audit
  bad="$(crumb_path "ftidBAD")"
  printf '{ not json' > "$bad"
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"ftidBAD","error":"x"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [[ "$output" == *"malformed breadcrumb"* ]] || [[ "$output" == *"warning"* ]]
  [ ! -f "$(audit_log)" ]
  [ ! -f "$bad" ]
}

@test "missing tool_use_id -> no crumb lookup, passthrough, no log" {
  enable_audit
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"error":"x"}'
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

@test "empty stdin -> passthrough, no log" {
  enable_audit
  run bash -c "printf '' | bash '$HANDLER'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
}

@test "tool_use_id with path-traversal characters -> sanitized, no traversal, breadcrumb preserved" {
  enable_audit
  # Plant a breadcrumb with an unrelated name that the empty-sanitized id
  # would never resolve to. The handler should find no crumb and no-op.
  write_breadcrumb "untouched" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"...///","error":"x"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"continue": true}'* ]]
  [ ! -f "$(audit_log)" ]
  [ -f "$(crumb_path "untouched")" ]
}

@test "log line round-trips through jq and carries ts + tool_use_id" {
  enable_audit
  write_breadcrumb "ftidRT" "Bash" '{"command":"ls"}' "" ""
  run_handler '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"ftidRT","error":"permission denied"}'
  [ "$status" -eq 0 ]

  line="$(head -n1 "$(audit_log)")"
  run jq -c '.' <<<"$line"
  [ "$status" -eq 0 ]
  for key in ts event source tool tool_use_id; do
    v="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$line")"
    [ -n "$v" ]
  done
}
