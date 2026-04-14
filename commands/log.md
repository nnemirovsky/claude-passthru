---
description: View passthru audit log
argument-hint: "[--since 1h] [--event ...] [--tool ...] [--tail N] [--format table|json|raw] [--enable|--disable|--status]"
---

# /passthru:log

Render the claude-passthru audit log in a readable table, filter by time
range / event / tool, or toggle the audit sentinel. Audit is OFF by default.
Enable it with `/passthru:log --enable`, which just touches
`~/.claude/passthru.audit.enabled` so the `PreToolUse` and `PostToolUse`
hooks start appending JSONL events to `~/.claude/passthru-audit.log`.

## What you must do

You are Claude. Shell out to the log script with `$ARGUMENTS` passed
through verbatim, then present the output clearly. Do not paraphrase the
script's output - quote it verbatim.

### 1. Run the log viewer

Invoke exactly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh $ARGUMENTS
```

Capture stdout, stderr, and the exit code.

The script accepts (see `--help` for the full list):

- `--since <value>` - filter by time. Accepts ISO 8601
  (`2026-04-14T00:00:00Z`), relative (`5m`, `1h`, `24h`, `7d`, `30d`), or
  `today`.
- `--event <regex>` - regex against the `.event` field
  (`allow`, `deny`, `passthrough`, `asked_allowed_once`,
  `asked_allowed_always`, `asked_allowed_unknown`, `asked_denied_once`,
  `asked_denied_always`).
- `--tool <regex>` - regex against the `.tool` field
  (e.g. `Bash`, `^mcp__`).
- `--format table|json|raw` - default `table` (ANSI color when stdout is a
  tty), `json` emits the filtered entries as a JSON array, `raw` passes
  the JSONL through unchanged.
- `--tail N` - last N entries after filtering.
- `--file <path>` - override the log path (defaults to
  `~/.claude/passthru-audit.log`).
- `--enable` / `--disable` / `--status` - toggle the audit sentinel at
  `~/.claude/passthru.audit.enabled`.

### 2. Present the result

Branch on the exit code:

**Exit 0, stdout has rows:** show the table (or JSON / raw block)
verbatim. Add a short one-liner summarizing what filter was applied, if
any, so the user knows which events they are looking at.

**Exit 0, stderr says `no entries`:** the log file is missing or empty, or
the filter matched nothing. Tell the user audit may be disabled (check
with `/passthru:log --status`) or the filter was too narrow.

**Exit 0, `--enable` / `--disable` / `--status`:** echo the script's line
back (`audit enabled`, `audit disabled`, `enabled`, `disabled`) along with
the log path so the user sees where events will land. If they just
enabled, remind them that audit imposes cost only while enabled and they
can disable it later.

**Exit 2:** the user passed a bad `--since` or an unknown flag. Surface
stderr verbatim and suggest re-running with `--help`.

### 3. Guidance

- Point out that `allow`/`deny` events are decisions this plugin made
  before the native permission dialog, while `asked_*` events represent
  the native dialog outcome for passthrough calls. Use `--event` to focus
  on one category.
- Remind the user that `--format raw` is ideal for piping into `jq` or
  `grep` for ad-hoc queries without quoting hassles.
- When audit is disabled (`--status` says `disabled`), nothing is being
  recorded. `/passthru:log --enable` turns it on with a single `touch`.

## Examples

- Tail the last 20 entries from the past hour:

  ```
  /passthru:log --since 1h --tail 20
  ```

- Show only native-dialog outcomes for Bash today:

  ```
  /passthru:log --since today --event '^asked_' --tool Bash
  ```

- Pipe the raw JSONL to jq (inside a shell):

  ```
  /passthru:log --format raw --since 24h
  ```

- Enable / disable / check audit:

  ```
  /passthru:log --enable
  /passthru:log --status
  /passthru:log --disable
  ```
