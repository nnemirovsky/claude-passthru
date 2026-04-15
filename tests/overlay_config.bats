#!/usr/bin/env bats

# tests/overlay_config.bats
# End-to-end coverage for scripts/overlay-config.sh (Task 9 overlay toggle).
# Hermetic via PASSTHRU_USER_HOME so the real ~/.claude is never touched.
# Multiplexer detection is exercised by toggling TMUX / KITTY_WINDOW_ID /
# WEZTERM_PANE plus planting stub binaries on PATH.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/overlay-config.sh"

  TMP="$(mktemp -d -t passthru-overlay-config.XXXXXX)"
  USER_ROOT="$TMP/user"
  BIN="$TMP/bin"
  mkdir -p "$USER_ROOT/.claude" "$BIN"

  export PASSTHRU_USER_HOME="$USER_ROOT"
  SENT_PATH="$USER_ROOT/.claude/passthru.overlay.disabled"

  # Pin PATH to a minimal skeleton with $BIN in front so tests that want a
  # multiplexer binary drop it in $BIN, and tests that want the binary
  # missing simply don't drop anything there. /usr/bin + /bin give us awk,
  # printf, rm, cat, etc. for the script body.
  MINIMAL_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export PATH="$MINIMAL_PATH"

  # Scrub every multiplexer env var so bats' parent shell never leaks
  # state into an assertion.
  unset TMUX
  unset KITTY_WINDOW_ID
  unset WEZTERM_PANE

  # Plain output (no ANSI, no tty quirks).
  export TERM=dumb
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Helpers -------------------------------------------------------------------

run_cfg() {
  run bash "$SCRIPT" "$@"
}

# plant_stub <name> - drop a no-op stub binary into $BIN so `command -v`
# succeeds. We don't care what the stub does since --status only queries
# PATH presence.
plant_stub() {
  local name="$1"
  cat > "$BIN/$name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$BIN/$name"
}

# ---------------------------------------------------------------------------
# --enable
# ---------------------------------------------------------------------------

@test "--enable with no sentinel -> still absent, exit 0, prints enabled" {
  [ ! -e "$SENT_PATH" ]
  run_cfg --enable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]
  [[ "$output" == *"overlay enabled"* ]]
  [[ "$output" == *"$SENT_PATH"* ]]
}

@test "--enable with existing sentinel -> removes, exit 0, idempotent" {
  touch "$SENT_PATH"
  [ -e "$SENT_PATH" ]
  run_cfg --enable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]
  [[ "$output" == *"overlay enabled"* ]]

  # Second --enable: still absent, still exit 0.
  run_cfg --enable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]
  [[ "$output" == *"overlay enabled"* ]]
}

# ---------------------------------------------------------------------------
# --disable
# ---------------------------------------------------------------------------

@test "--disable with no sentinel -> creates, exit 0, prints disabled" {
  [ ! -e "$SENT_PATH" ]
  run_cfg --disable
  [ "$status" -eq 0 ]
  [ -e "$SENT_PATH" ]
  [[ "$output" == *"overlay disabled"* ]]
  [[ "$output" == *"$SENT_PATH"* ]]
}

@test "--disable with existing sentinel -> still present, exit 0, idempotent" {
  touch "$SENT_PATH"
  run_cfg --disable
  [ "$status" -eq 0 ]
  [ -e "$SENT_PATH" ]
  [[ "$output" == *"overlay disabled"* ]]

  # Second --disable: still present, still exit 0.
  run_cfg --disable
  [ "$status" -eq 0 ]
  [ -e "$SENT_PATH" ]
  [[ "$output" == *"overlay disabled"* ]]
}

# ---------------------------------------------------------------------------
# --status (sentinel side)
# ---------------------------------------------------------------------------

@test "--status with no sentinel -> enabled, exit 0, sentinel path printed" {
  [ ! -e "$SENT_PATH" ]
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlay: enabled"* ]]
  [[ "$output" == *"$SENT_PATH"* ]]
}

@test "--status with sentinel -> disabled, exit 0, sentinel path printed" {
  touch "$SENT_PATH"
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlay: disabled"* ]]
  [[ "$output" == *"$SENT_PATH"* ]]
}

# ---------------------------------------------------------------------------
# --status (multiplexer detection)
# ---------------------------------------------------------------------------

@test "--status with no multiplexer env vars -> reports 'none detected'" {
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"multiplexer:"* ]]
  [[ "$output" == *"none detected"* ]]
}

@test "--status with TMUX set but tmux NOT on PATH -> binary missing" {
  export TMUX="mock/session"
  # No stub planted -> tmux not on PATH.
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"multiplexer:"* ]]
  [[ "$output" == *"tmux"* ]]
  [[ "$output" == *"binary missing"* ]]
}

@test "--status with TMUX set + tmux stub on PATH -> detected + binary on PATH" {
  export TMUX="mock/session"
  plant_stub tmux
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"multiplexer:"* ]]
  [[ "$output" == *"detected: tmux"* ]]
  [[ "$output" == *"binary on PATH"* ]]
}

@test "--status with KITTY_WINDOW_ID set + kitty stub on PATH -> detected kitty" {
  export KITTY_WINDOW_ID="42"
  plant_stub kitty
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"detected: kitty"* ]]
  [[ "$output" == *"KITTY_WINDOW_ID"* ]]
}

@test "--status with WEZTERM_PANE set without binary -> wezterm binary missing" {
  export WEZTERM_PANE="abc123"
  # No stub planted -> wezterm not on PATH.
  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"wezterm"* ]]
  [[ "$output" == *"binary missing"* ]]
}

# ---------------------------------------------------------------------------
# --help / -h
# ---------------------------------------------------------------------------

@test "--help prints usage and exits 0" {
  run_cfg --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--enable"* ]]
  [[ "$output" == *"--disable"* ]]
  [[ "$output" == *"--status"* ]]
}

@test "-h is an alias for --help" {
  run_cfg -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--enable"* ]]
}

# ---------------------------------------------------------------------------
# Argument errors
# ---------------------------------------------------------------------------

@test "no args -> usage to stderr, exit 2" {
  run_cfg
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* || "$output" == *"no action"* ]]
}

@test "unknown flag -> error on stderr, exit 2" {
  run_cfg --unknown-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "--enable --disable together -> error, exit 2" {
  run_cfg --enable --disable
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [[ "$output" == *"--enable"* ]]
  [[ "$output" == *"--disable"* ]]
}

@test "--enable --status together -> error, exit 2" {
  run_cfg --enable --status
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "--disable --status together -> error, exit 2" {
  run_cfg --disable --status
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

# ---------------------------------------------------------------------------
# Round-trip: enable -> disable -> enable -> status
# ---------------------------------------------------------------------------

@test "round trip: enable, disable, status, enable, status" {
  run_cfg --enable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]

  run_cfg --disable
  [ "$status" -eq 0 ]
  [ -e "$SENT_PATH" ]

  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlay: disabled"* ]]

  run_cfg --enable
  [ "$status" -eq 0 ]
  [ ! -e "$SENT_PATH" ]

  run_cfg --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlay: enabled"* ]]
}
