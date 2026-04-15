---
description: Toggle the passthru permission-prompt overlay
argument-hint: "[--enable|--disable|--status]"
---

# /passthru:overlay

Turn the claude-passthru permission-prompt overlay on or off, or check its
current state. The overlay is a small in-terminal popup (rendered via the
active multiplexer: tmux, kitty, or wezterm) that intercepts ask rules and
passthrough tool calls before they reach Claude Code's native permission
dialog. Disabling it restores the native dialog.

The overlay is ON by default when a supported multiplexer is detected. Use
`--disable` if the popup misbehaves in your terminal or if you simply
prefer Claude Code's built-in dialog. The sentinel that controls the
toggle lives at `~/.claude/passthru.overlay.disabled` (absent = enabled,
present = disabled).

## What you must do

You are Claude. Shell out to the overlay-config script with `$ARGUMENTS`
passed through verbatim, then present the output clearly. Do not
paraphrase the script's output. Quote it verbatim so the user sees the
exact sentinel path.

### 1. Run the toggle

Invoke exactly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/overlay-config.sh $ARGUMENTS
```

Capture stdout, stderr, and the exit code.

The script accepts (see `--help` for the full list):

- `--enable` - remove the sentinel, re-enabling the overlay. Idempotent
  (running twice is fine). Exit 0.
- `--disable` - create the sentinel, disabling the overlay. The next
  passthrough call will fall through to Claude Code's native permission
  dialog. Idempotent. Exit 0.
- `--status` - print `overlay: enabled` or `overlay: disabled`, the
  sentinel path, and a one-line multiplexer detection summary (which env
  var is set and whether the binary is on PATH). Exit 0.
- `--help` / `-h` - short usage. Exit 0.

### 2. Present the result

Branch on the exit code:

**Exit 0, `--enable` / `--disable`:** echo the script's confirmation line
back verbatim along with the sentinel path. If the user just disabled,
remind them that they can re-enable later with `/passthru:overlay
--enable`.

**Exit 0, `--status`:** quote the three lines the script prints. If the
`multiplexer:` line says `none detected` or `binary missing`, point out
that even with the overlay enabled the hook will fall through to the
native dialog because the overlay cannot be launched.

**Exit 2:** the user passed no flag, an unknown flag, or two exclusive
flags together (for example `--enable --disable`). Surface stderr
verbatim and suggest re-running with `--help`.

### 3. Guidance

- Use `--status` first when troubleshooting why the overlay isn't showing
  up. The multiplexer line tells you whether the hook can even launch the
  popup.
- If overlay is misbehaving inside tmux (rendering artifacts, menu not
  responding) run `--disable` to fall back to the native dialog. This
  has no effect on ask rules themselves, only on where the prompt is
  rendered.
- On systems without a supported multiplexer (plain terminal, ssh session
  without tmux) the overlay cannot be launched anyway. Leaving it
  `--enable` there is harmless, but `--disable` silences the hook's
  "overlay unavailable" internal audit event.
- Re-enabling is as cheap as a single file removal. No session restart
  needed.

## Examples

- Check current state and multiplexer detection:

  ```
  /passthru:overlay --status
  ```

- Disable the overlay (falls back to Claude Code's native dialog):

  ```
  /passthru:overlay --disable
  ```

- Re-enable the overlay:

  ```
  /passthru:overlay --enable
  ```
