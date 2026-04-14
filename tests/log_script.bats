#!/usr/bin/env bats

# tests/log_script.bats
# End-to-end coverage for scripts/log.sh. Hermetic via PASSTHRU_USER_HOME so
# real ~/.claude is never touched. Timestamps in the fixture log are generated
# at test time relative to `date -u +%s` so --since cases stay deterministic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LOG_SCRIPT="$REPO_ROOT/scripts/log.sh"

  TMP="$(mktemp -d -t passthru-log.XXXXXX)"
  USER_ROOT="$TMP/user"
  mkdir -p "$USER_ROOT/.claude"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  LOG_PATH="$USER_ROOT/.claude/passthru-audit.log"
  SENT_PATH="$USER_ROOT/.claude/passthru.audit.enabled"

  # Force "not a tty" behaviour in renderers so ANSI escape codes never leak
  # into captured output.
  export TERM=dumb
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Helpers -------------------------------------------------------------------

# iso_from_epoch <epoch>: emit ISO 8601 Z-form.
iso_from_epoch() {
  local e="$1"
  if [ "$(uname -s)" = "Darwin" ]; then
    date -u -j -f '%s' "$e" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
  fi
}

run_log() {
  run bash "$LOG_SCRIPT" "$@"
}

# Write a mixed fixture log with deterministic timestamps: 2 hours ago,
# 30 min ago, 5 min ago, and "now" (roughly).
write_fixture() {
  local now t_2h t_30m t_5m t_now
  now="$(date -u +%s)"
  t_2h=$((now - 7200))
  t_30m=$((now - 1800))
  t_5m=$((now - 300))
  t_now="$now"

  cat > "$LOG_PATH" <<EOF
{"ts":"$(iso_from_epoch "$t_2h")","event":"allow","source":"passthru","tool":"Bash","reason":"two-hours-old","rule_index":0,"pattern":"^bash /old/","tool_use_id":"old1"}
{"ts":"$(iso_from_epoch "$t_30m")","event":"deny","source":"passthru","tool":"Bash","reason":"blocked rm -rf","rule_index":0,"pattern":"rm -rf /","tool_use_id":"mid1"}
{"ts":"$(iso_from_epoch "$t_5m")","event":"passthrough","source":"passthru","tool":"Read","reason":null,"rule_index":null,"pattern":null,"tool_use_id":"recent1"}
{"ts":"$(iso_from_epoch "$t_now")","event":"asked_allowed_once","source":"native","tool":"Read","tool_use_id":"recent1"}
EOF
}

# Tests ---------------------------------------------------------------------

# -- sentinel toggle --------------------------------------------------------

@test "--enable creates sentinel file and prints confirmation" {
  [ ! -e "$SENT_PATH" ]
  run_log --enable
  [ "$status" -eq 0 ]
  [ -e "$SENT_PATH" ]
  [[ "$output" == *"audit enabled"* ]]
  [[ "$output" == *"$LOG_PATH"* ]]
}

@test "--disable removes sentinel file and is idempotent" {
  touch "$SENT_PATH"
  run_log --disable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]
  [[ "$output" == *"audit disabled"* ]]

  # Second call -> still ok (rm -f semantics).
  run_log --disable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]
  [[ "$output" == *"audit disabled"* ]]
}

@test "--status reports disabled when sentinel missing" {
  run_log --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
  [[ "$output" == *"$LOG_PATH"* ]]
}

@test "--status reports enabled when sentinel present" {
  touch "$SENT_PATH"
  run_log --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled"* ]]
  [[ "$output" == *"$LOG_PATH"* ]]
}

# -- empty/missing handling -------------------------------------------------

@test "missing log file -> 'no entries' on stderr, exit 0" {
  [ ! -e "$LOG_PATH" ]
  run_log
  [ "$status" -eq 0 ]
  [[ "$output" == *"no entries"* ]]
}

@test "empty log file -> 'no entries' on stderr, exit 0" {
  : > "$LOG_PATH"
  run_log
  [ "$status" -eq 0 ]
  [[ "$output" == *"no entries"* ]]
}

# -- filter: --event --------------------------------------------------------

@test "--event allow selects only allow entries" {
  write_fixture
  run_log --event '^allow$' --format raw
  [ "$status" -eq 0 ]
  # Exactly one line matches.
  local count
  count="$(printf '%s\n' "$output" | grep -c '"event":"allow"' || true)"
  [ "$count" -eq 1 ]
  # No deny / passthrough / asked_* leaked through.
  printf '%s\n' "$output" | grep -q '"event":"deny"' && return 1
  printf '%s\n' "$output" | grep -q '"event":"passthrough"' && return 1
  printf '%s\n' "$output" | grep -q '"event":"asked_' && return 1
  return 0
}

@test "--event '^asked_' selects only native-dialog events" {
  write_fixture
  run_log --event '^asked_' --format raw
  [ "$status" -eq 0 ]
  local count
  count="$(printf '%s\n' "$output" | grep -c '"event":"asked_' || true)"
  [ "$count" -eq 1 ]
}

# -- filter: --tool ---------------------------------------------------------

@test "--tool Bash selects only Bash tool entries" {
  write_fixture
  run_log --tool Bash --format raw
  [ "$status" -eq 0 ]
  # Two Bash lines in the fixture.
  local count
  count="$(printf '%s\n' "$output" | grep -c '"tool":"Bash"' || true)"
  [ "$count" -eq 2 ]
  # No Read lines in output.
  printf '%s\n' "$output" | grep -q '"tool":"Read"' && return 1
  return 0
}

# -- filter: --since --------------------------------------------------------

@test "--since 1h excludes entries older than an hour" {
  write_fixture
  run_log --since 1h --format raw
  [ "$status" -eq 0 ]
  # Two-hour-old allow entry must be excluded.
  printf '%s\n' "$output" | grep -q 'two-hours-old' && return 1
  # 30m, 5m, now entries must all be present.
  [[ "$output" == *"blocked rm -rf"* ]]
  [[ "$output" == *'"tool_use_id":"recent1"'* ]]
  return 0
}

@test "--since 7d keeps all fixture entries" {
  write_fixture
  run_log --since 7d --format raw
  [ "$status" -eq 0 ]
  local n
  n="$(printf '%s\n' "$output" | grep -c '"ts":' || true)"
  [ "$n" -eq 4 ]
}

@test "--since 5m keeps only the 5-min and now entries" {
  write_fixture
  run_log --since 5m --format raw
  [ "$status" -eq 0 ]
  # The 5-min-old entry is right on the cutoff. Allow either 1 or 2 recent
  # entries but the older ones must be gone.
  printf '%s\n' "$output" | grep -q 'two-hours-old' && return 1
  printf '%s\n' "$output" | grep -q 'blocked rm -rf' && return 1
  # "recent1" appears in two entries (passthrough + asked_allowed_once).
  # At least one of them should be present.
  [[ "$output" == *'"tool_use_id":"recent1"'* ]]
  return 0
}

@test "--since with bad value exits 2 with stderr" {
  write_fixture
  run_log --since nonsense --format raw
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --since"* ]]
}

@test "--since with ISO 8601 epoch is accepted" {
  write_fixture
  # Use a cutoff well in the past so everything matches.
  run_log --since '2020-01-01T00:00:00Z' --format raw
  [ "$status" -eq 0 ]
  local n
  n="$(printf '%s\n' "$output" | grep -c '"ts":' || true)"
  [ "$n" -eq 4 ]
}

# -- --format json ----------------------------------------------------------

@test "--format json emits a valid JSON array" {
  write_fixture
  run_log --format json
  [ "$status" -eq 0 ]
  # Feed the captured stdout into jq '.' to validate.
  printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
  # All four entries are in the array.
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" -eq 4 ]
}

@test "--format json + --event deny returns a 1-element array" {
  write_fixture
  run_log --format json --event deny
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
  local n
  n="$(printf '%s' "$output" | jq 'length')"
  [ "$n" -eq 1 ]
  local ev
  ev="$(printf '%s' "$output" | jq -r '.[0].event')"
  [ "$ev" = "deny" ]
}

# -- --format raw -----------------------------------------------------------

@test "--format raw passes JSONL through unchanged (whitespace-insensitive)" {
  write_fixture
  run_log --format raw
  [ "$status" -eq 0 ]

  # Normalize both sides: strip trailing newlines, compare byte-for-byte.
  local got expected
  got="$(printf '%s' "$output")"
  expected="$(cat "$LOG_PATH")"
  # Trim trailing newline on expected.
  while [ "${expected: -1}" = $'\n' ]; do expected="${expected%$'\n'}"; done
  [ "$got" = "$expected" ]
}

# -- --tail ----------------------------------------------------------------

@test "--tail 2 returns the last 2 entries after filtering" {
  write_fixture
  run_log --tail 2 --format raw
  [ "$status" -eq 0 ]
  local n
  n="$(printf '%s\n' "$output" | grep -c '"ts":' || true)"
  [ "$n" -eq 2 ]
  # Last two entries are passthrough + asked_allowed_once.
  [[ "$output" == *'"event":"passthrough"'* ]]
  [[ "$output" == *'"event":"asked_allowed_once"'* ]]
  printf '%s\n' "$output" | grep -q '"event":"allow"' && return 1
  printf '%s\n' "$output" | grep -q '"event":"deny"' && return 1
  return 0
}

@test "--tail 2 combined with --event filters first then tails" {
  write_fixture
  # Only two "passthru" source entries: allow + deny. --tail 2 of that list
  # should keep both.
  run_log --event '^(allow|deny)$' --tail 2 --format raw
  [ "$status" -eq 0 ]
  local n
  n="$(printf '%s\n' "$output" | grep -c '"ts":' || true)"
  [ "$n" -eq 2 ]
  [[ "$output" == *'"event":"allow"'* ]]
  [[ "$output" == *'"event":"deny"'* ]]
}

# -- malformed lines -------------------------------------------------------

@test "malformed line mid-log -> stderr warning, subsequent lines processed" {
  write_fixture
  # Insert a bogus line in the middle of the fixture.
  local tmp
  tmp="$(mktemp)"
  awk 'NR==2 {print; print "not-a-json-line"; next} {print}' "$LOG_PATH" > "$tmp"
  mv "$tmp" "$LOG_PATH"

  run_log --format raw
  [ "$status" -eq 0 ]
  # Warning on stderr. bats captures stderr+stdout in $output by default, so
  # the warning string should appear somewhere.
  [[ "$output" == *"warning"* ]] || [[ "$output" == *"skipping"* ]]
  # The four valid lines still render.
  local n
  n="$(printf '%s\n' "$output" | grep -c '"ts":' || true)"
  [ "$n" -eq 4 ]
}

# -- --file override -------------------------------------------------------

@test "--file overrides the default log path" {
  local alt
  alt="$TMP/custom.log"
  cat > "$alt" <<EOF
{"ts":"$(iso_from_epoch "$(date -u +%s)")","event":"allow","source":"passthru","tool":"Bash","reason":"custom","rule_index":0,"pattern":"","tool_use_id":"c1"}
EOF
  run_log --file "$alt" --format raw
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom"* ]]
}

# -- help ------------------------------------------------------------------

@test "--help prints usage and exits 0" {
  run_log --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: log.sh"* ]]
  [[ "$output" == *"--since"* ]]
  [[ "$output" == *"--enable"* ]]
}

# -- unknown argument ------------------------------------------------------

@test "unknown argument exits 2" {
  run_log --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "--format bogus exits 2" {
  run_log --format bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --format"* ]]
}

@test "--tail non-numeric exits 2" {
  run_log --tail abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"--tail"* ]]
}

# -- table format ----------------------------------------------------------

@test "default table format renders header + rows" {
  write_fixture
  run_log
  [ "$status" -eq 0 ]
  [[ "$output" == *"time"* ]]
  [[ "$output" == *"event"* ]]
  [[ "$output" == *"source"* ]]
  [[ "$output" == *"tool"* ]]
  [[ "$output" == *"reason/detail"* ]]
  # Column separator char appears.
  [[ "$output" == *"|"* ]]
  # Reason strings appear.
  [[ "$output" == *"blocked rm -rf"* ]]
}

@test "table truncates long reasons to fit ~60 chars with ellipsis" {
  # Overwrite the log with one line whose reason is 100 chars.
  local longreason
  longreason="$(printf 'x%.0s' $(seq 1 100))"
  cat > "$LOG_PATH" <<EOF
{"ts":"$(iso_from_epoch "$(date -u +%s)")","event":"allow","source":"passthru","tool":"Bash","reason":"$longreason","rule_index":0,"pattern":"","tool_use_id":"t1"}
EOF
  run_log
  [ "$status" -eq 0 ]
  # Ellipsis present in reason column.
  [[ "$output" == *"..."* ]]
  # Full 100-char reason is NOT in output.
  if printf '%s' "$output" | grep -q "$longreason"; then
    return 1
  fi
  return 0
}
