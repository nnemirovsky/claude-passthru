# passthru

Regex-based permission rules for Claude Code via hooks.

[![Tests](https://github.com/nnemirovsky/claude-passthru/actions/workflows/tests.yml/badge.svg)](https://github.com/nnemirovsky/claude-passthru/actions/workflows/tests.yml)
[![Release](https://img.shields.io/github/v/release/nnemirovsky/claude-passthru)](https://github.com/nnemirovsky/claude-passthru/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

The native permission system in Claude Code only takes glob wildcards at the end of a pattern, which leaves big gaps. `passthru` adds a thin regex layer in front of it so you can auto-allow (or deny) tool calls by shape instead of listing each command. It sits on top of your existing `settings.json` and leaves everything that does not match to the native dialog.

## Quick example

Native `Bash(bash /Users/you/project/:*)` does not match `bash /Users/you/project/script.sh` because Claude Code enforces a word boundary after the prefix. You end up listing every script by name, or giving up and granting the full `Bash(bash:*)` namespace.

With passthru, one rule does what you meant in the first place:

```json
{ "tool": "Bash", "match": { "command": "^bash /Users/you/project/" }, "reason": "run project scripts" }
```

More examples: shape-matching a `gh api` endpoint across any owner/repo pair, allowing every tool on an MCP server, denying `rm -rf /` globally. See [Rule format reference](#rule-format-reference) and [`docs/examples.md`](docs/examples.md).

## Install

```
/plugin marketplace add nnemirovsky/claude-passthru
/plugin install passthru
```

## What you can do

* **Regex-based Bash prefixes.** Auto-allow a directory of scripts, a shell pipeline, or any command family the native glob syntax cannot express.
* **Compound command splitting.** `ls | head && echo done` is split into three segments. Each segment is matched independently. Deny on ANY segment blocks the whole command. Allow requires ALL segments to match. Mirrors Claude Code's `splitCommand()` approach.
* **Read-only command auto-allow.** Common read-only commands (`cat`, `head`, `tail`, `ls`, `wc`, `stat`, `diff`, `jq`, etc.) are auto-allowed without explicit rules when their path arguments stay inside the working directory or allowed dirs. Mirrors Claude Code's `makeRegexForSafeCommand()` pattern.
* **Shape-aware path and URL rules.** Match on the structure of a path or URL (e.g. `^gh api /repos/[^/]+/[^/]+/forks`) so you pin the endpoint, not the owner.
* **MCP tool namespaces.** Allow a whole MCP server family with a single tool-regex rule, no need to enumerate every tool.
* **Deny lists that win.** A matching deny rule unconditionally overrides any allow, so you can cement safety rules on top of a permissive allow set.
* **Ask rules that route to the overlay (or native dialog as fallback).** Mark a tool shape as "always prompt me" via `ask[]`. Routes to the passthru overlay when enabled, falls back to Claude Code's native dialog otherwise.
* **Terminal overlay for permission prompts with Y/A/N/D keyboard flow.** Inline TUI popup inside your tmux / kitty / wezterm session that intercepts permission prompts. Single-keystroke yes-once / yes-always / no-once / no-always. Escape drops through to the native dialog. Proposed Bash rules are fully anchored with CC's safe character class to block compound operator injection.
* **Additional allowed directories.** Extend the trusted directory set beyond cwd via `allowed_dirs` in passthru.json. Bootstrap imports Claude Code's `additionalAllowedWorkingDirs` automatically.
* **Internal tool auto-allow.** Agent, Skill, and Glob are auto-allowed without rules or prompts. No more "Use skill?" confirmations.
* **Opt-in audit log.** JSONL record of every decision (including what the native dialog did for passthroughs). Off by default, zero overhead when disabled.
* **Standalone verifier.** Validate every rule file from the command line or via `/passthru:verify` to catch bad JSON, invalid regex, and allow/deny conflicts before they silently disable rules.
* **First-run bootstrap.** One-shot `/passthru:bootstrap` command (or `scripts/bootstrap.sh` for scripting) that converts existing native `permissions.allow` entries into passthru rules. A `SessionStart` hint fires whenever `settings.json` has importable entries that are not yet in `passthru.imported.json` and auto-silences after the next bootstrap run.

## Commands

All commands are plugin-namespaced under `/passthru:`.

| Command | What it does |
| --- | --- |
| `/passthru:bootstrap` | One-shot importer: reviews your existing `permissions.allow` entries, shows the proposed rules, asks to confirm, then writes `passthru.imported.json`. Runs the verifier afterwards. |
| `/passthru:add` | Add a rule without hand-editing `passthru.json`. Supports `--allow` (default), `--ask`, `--deny`, and `--field`. |
| `/passthru:suggest` | Propose a generalized rule from a recent tool call in the conversation, then write it on confirmation. |
| `/passthru:list` | Show every rule across user and project scopes, grouped by `(scope, list, source)` with 1-based indexes. Filter by `--scope`, `--list`, `--source`, or `--tool`. |
| `/passthru:remove` | Remove an authored rule by `<scope> <list> <index>`. Indexes match the numbering from `/passthru:list`. Imported (bootstrap-generated) rules are not removable here; edit `settings.json` and re-run bootstrap instead. |
| `/passthru:verify` | Validate every rule file. Surfaces parse errors, schema violations, invalid regex, duplicates, and allow/deny conflicts. |
| `/passthru:log` | Read the audit log with filters. Also toggles the audit sentinel on/off. |
| `/passthru:overlay` | Toggle the permission-prompt overlay on or off. `--status` also reports which multiplexer the hook detects. |

Full reference in the [Command reference](#command-reference) section below.

---

## Requirements

Runtime dependencies the plugin needs on the user's machine.

* **bash 3.2+** or **bash 4.0+**. The hook scripts are written to POSIX/bash 3.2 (no associative arrays, no `declare -n`, no `mapfile`). macOS ships bash 3.2 by default and Linux distros ship bash 4+, both work.
* **jq 1.6+**. Used to parse rule files and build JSON output.
  * macOS: `brew install jq`
  * Debian/Ubuntu: `apt install jq`
  * RHEL/Fedora: `dnf install jq`
* **perl 5+**. Used as the PCRE regex engine because BSD grep on macOS lacks `-P`. Preinstalled on macOS and essentially every Linux distribution.
* **bats-core 1.9+** (tests only, not required to run the plugin).
  * macOS: `brew install bats-core`
  * Debian/Ubuntu: `apt install bats` (usually older, prefer npm)
  * npm (any platform): `npm install -g bats`

**PowerShell support:** the hook itself is Bash plus perl only. PowerShell rule matching works because Claude Code still invokes the `PreToolUse` hook for `PowerShell` tool calls. No PowerShell runtime is needed on the user's machine for the plugin itself.

## How it works

Native rules solve the common case. They fall short when:

* The thing you want to match is not space-delimited after a prefix (directory paths, URL paths).
* You need to pin the shape of a sub-argument, not just the leading verb.
* You want to allow a whole MCP server family without listing every tool.
* You want a deny list that unconditionally overrides a more permissive allow.

`passthru` adds a thin regex layer in front of the native system. When a passthru rule matches, the hook emits a decision and Claude Code skips the permission dialog. When nothing matches, control passes through to the native rules unchanged. Nothing about your existing `settings.json` or `.claude/settings.local.json` changes.

For Bash commands, passthru splits compound commands (piped, chained with `&&`/`||`/`;`/`&`) into segments and matches each one independently. Read-only commands (`cat`, `head`, `ls`, `wc`, etc.) are auto-allowed when their path arguments stay inside the working directory or configured allowed directories.

Works across every tool Claude Code exposes (`Bash`, `PowerShell`, `Read`, `Edit`, `Write`, `WebFetch`, MCP tools, and so on).

## First-run bootstrap

The plugin ships a bootstrap importer that converts existing native `permissions.allow` entries into passthru rule files. It reads up to three settings files: the user-scope `~/.claude/settings.json`, the project-scope shared `./.claude/settings.json`, and the project-scope local `./.claude/settings.local.json`. Run it once after install to avoid starting from zero.

**Recommended:** run `/passthru:bootstrap` inside a Claude Code session. It dry-runs first, shows the rules it would import, asks you to confirm, then writes and verifies. Use `--user-only` or `--project-only` to narrow the scope.

**Non-interactive:** the same logic is available as a plain shell script for CI or ad-hoc use. Dry run first (prints proposed rules to stdout, writes nothing):

```
bash ~/.claude/plugins/marketplaces/nnemirovsky/claude-passthru/scripts/bootstrap.sh
```

The exact path depends on where Claude Code installed the plugin. If you cloned the repo directly, the script lives at `scripts/bootstrap.sh` in your clone. Inspect the output, then re-run with `--write` to persist:

```
bash .../scripts/bootstrap.sh --write
```

`--write` mode also runs `scripts/verify.sh --quiet` after writing. If the verifier finds errors, the script restores the pre-write backup and exits non-zero.

**What bootstrap converts.** Six native rule shapes are recognized:

| Native rule | Converted to |
| --- | --- |
| `Bash(<prefix>:*)` | `{"tool": "Bash", "match": {"command": "^<prefix>(\\s|$)"}}` |
| `Bash(<exact command>)` | `{"tool": "Bash", "match": {"command": "^<exact>$"}}` |
| `mcp__server__tool` | `{"tool": "^mcp__server__tool$"}` |
| `WebFetch(domain:x.com)` | `{"tool": "WebFetch", "match": {"url": "^https?://([^/.]+\\.)*x\\.com([/:?#]\|$)"}}` |
| `WebSearch` | `{"tool": "^WebSearch$"}` |
| `Read(<path>)`, `Edit(<path>)`, `Write(<path>)` | `{"tool": "^Read$", "match": {"file_path": "^<path>$"}}` (exact) or `"^<path>(/\|$)"` when the native rule ends in `/**` or `/*` |
| `Skill(<name>)` | `{"tool": "^Skill$", "match": {"skill": "^<name>$"}}` |

Regex metacharacters in the original path/prefix/name are escaped so the converted pattern matches literally. Anything that does not match one of the shapes above is skipped with a `[WARN]` line on stderr (for example, custom MCP tool patterns that do not start with `mcp__`, or a `WebFetch(...)` with a non-`domain:` argument).

For `Read`, `Edit`, and `Write`, path acceptance is permissive: redundant slash runs (`//foo`, `///foo/bar`) are collapsed to a single slash, `~/...` expands to `$HOME/...`, and paths with spaces or deep nesting are accepted. Only clearly invalid shapes are skipped with a `[WARN]`:

* shell / env expansion: `$VAR`, `${VAR}`, `$(cmd)`, `%VAR%`
* zsh equals expansion: leading `=` (e.g. `=cmd`)
* tilde variants other than `~/`: `~user`, `~+`, `~-`, `~N`
* UNC paths: leading `\\server\share`

Bootstrap writes to dedicated imported files so hand-curated rules in `passthru.json` stay separate:

* `~/.claude/passthru.imported.json` (user scope)
* `.claude/passthru.imported.json` (project scope)

Re-running bootstrap overwrites the imported files. Edit `passthru.json` (the authored file) for hand-managed rules. Both files are merged at hook time.

**SessionStart hint.** The plugin ships a `SessionStart` hook that detects importable `permissions.allow` entries in `settings.json` that are not yet covered by a rule in `passthru.imported.json`. Each imported rule carries a `_source_hash` field recording which settings entry it came from, so the hint compares the two hash sets on every session start. The hint fires until the last un-imported entry is covered, then auto-silences. Run `/passthru:bootstrap` once and it will not fire again unless you add new native entries later.

## Rule format reference

Rule files are JSON with the shape:

```json
{
  "version": 2,
  "allow": [ { "tool": "...", "match": { "...": "..." }, "reason": "..." } ],
  "deny":  [ { "tool": "...", "match": { "...": "..." }, "reason": "..." } ],
  "ask":   [ { "tool": "...", "match": { "...": "..." }, "reason": "..." } ]
}
```

`version: 1` files (no `ask[]` key) continue to load unchanged. `ask[]` is v2-only. See [Ask rules](#ask-rules) below for when to use it.

Four examples covering common use cases.

**Directory prefix (Bash).** Auto-allow any `bash` invocation against a scripts dir:

```json
{ "tool": "Bash", "match": { "command": "^bash /Users/you/scripts/" }, "reason": "local scripts" }
```

**Regex on gh api endpoints (Bash).** Auto-allow repo forks queries across any owner/repo:

```json
{ "tool": "Bash", "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" }, "reason": "github forks api reads" }
```

**MCP namespace (no match block).** Auto-allow every tool on the `gemini-cli` MCP server:

```json
{ "tool": "^mcp__gemini-cli__", "reason": "gemini mcp server" }
```

**Deny rule (priority over allow).** Block destructive `rm -rf /` patterns across any shell tool, even if a broader allow would match:

```json
{ "tool": "Bash|PowerShell", "match": { "command": "rm\\s+-rf\\s+/" }, "reason": "safety" }
```

See [`docs/rule-format.md`](docs/rule-format.md) for the full schema reference and [`docs/examples.md`](docs/examples.md) for more examples.

## Command reference

All commands are plugin-namespaced under `/passthru:`.

### `/passthru:add`

Add a rule without hand-editing `passthru.json`. Canonical call:

```
/passthru:add user Bash "^gh api /repos/[^/]+/[^/]+/forks" "github forks api reads"
```

Flags: `--deny` (write to deny list instead of allow), `--field <name>` (override the default `tool_input` field).

### `/passthru:suggest`

Propose a generalized rule from a recent tool call in the conversation. The command scans the transcript, drafts a regex that generalizes owner / repo / version-style variables, shows matched and non-matched examples, and on confirmation hands off to the same write wrapper `/passthru:add` uses.

```
/passthru:suggest gh api
```

### `/passthru:list`

Show every rule across user and project scopes. Rules are grouped by `(scope, list, source)` and numbered with 1-based indexes that match what `/passthru:remove` expects.

```
/passthru:list
/passthru:list --scope user --list deny
/passthru:list --source imported
/passthru:list --tool '^Bash$'
/passthru:list --flat
/passthru:list --format json
```

### `/passthru:remove`

Remove an authored rule by `<scope> <list> <index>`. Run `/passthru:list` first to see the indexes.

```
/passthru:remove user allow 3
/passthru:remove project deny 1
```

Imported rules (written by `/passthru:bootstrap`) are not removable here because bootstrap regenerates them on every run. To drop one, remove the corresponding `permissions.allow` entry from `settings.json` and re-run bootstrap.

### `/passthru:verify`

Validate every rule file. Surfaces parse errors, schema violations, invalid regex, duplicates, and allow+deny conflicts.

```
/passthru:verify
/passthru:verify --scope user --strict
```

### `/passthru:log`

Read the audit log in a filtered table (see [Audit log](#audit-log) below). Also toggles the audit sentinel.

```
/passthru:log --since 1h --tail 20
/passthru:log --enable
```

### `/passthru:overlay`

Toggle the in-terminal permission-prompt overlay (see [Overlay](#overlay) below), or inspect its current state plus multiplexer detection.

```
/passthru:overlay --status
/passthru:overlay --disable
/passthru:overlay --enable
```

`--status` prints the current enabled/disabled state, the sentinel path, and whether a supported multiplexer (tmux, kitty, wezterm) is detected and runnable on PATH.

## Overlay

The overlay is an in-terminal TUI popup that intercepts permission prompts before they reach Claude Code's native dialog. When the overlay fires you see a single-keystroke menu:

```
Passthru Permission Prompt

Tool:   Bash
Input:  gh api /repos/anthropics/claude-code/forks?page=2

[Y] Yes, once
[A] Yes, always (write rule)
[N] No, once
[D] No, always (deny rule)
[Esc] Skip (use native dialog)
```

Picking `A` or `D` drops you into a second screen where you can accept or hand-edit the proposed regex before the rule is written to `passthru.json`.

**On by default.** The overlay is enabled out of the box on every supported multiplexer. No configuration needed.

**Opt-out.** Drop the overlay with `/passthru:overlay --disable` (or `touch ~/.claude/passthru.overlay.disabled`). Passthru will emit `permissionDecision: "ask"` instead, Claude Code shows its built-in dialog, and you still get the same yes-once / yes-always / no-once / no-always outcomes via the native UI. Re-enable with `/passthru:overlay --enable`.

**Sentinel path.** `~/.claude/passthru.overlay.disabled`. Absent = overlay enabled, present = overlay disabled. The `/passthru:overlay` command is a thin wrapper around this file.

**Supported multiplexers.**

| Multiplexer | Detection env var | Popup command used |
| --- | --- | --- |
| tmux | `$TMUX` | `tmux display-popup -E -w 80% -h 60%` |
| kitty | `$KITTY_WINDOW_ID` | `kitty @ launch --type=overlay` |
| wezterm | `$WEZTERM_PANE` | `wezterm cli split-pane` (adjacent pane) |

The hook picks the first detected multiplexer whose binary is also on `$PATH`. If none match, the hook falls through to Claude Code's native dialog.

**When the overlay fires.** The hook runs the normal decision pipeline first. The overlay only fires when nothing else matched:

1. `deny` rule match -> immediate deny, no overlay. For compound Bash commands, ANY segment matching deny blocks the whole command.
2. Read-only auto-allow -> immediate allow, no overlay. ALL segments must be readonly with valid paths.
3. `allow` rule match -> immediate allow, no overlay. For compound Bash commands, ALL segments must match.
4. `ask` rule match -> overlay (or native dialog as fallback). An ask-rule match wins over the permission-mode auto-allow shortcut below, because ask expresses explicit "prompt me" intent.
5. No rule match -> check Claude Code's `permission_mode` auto-allow rules: `bypassPermissions` (everything), `acceptEdits` + Write/Edit within cwd or allowed dirs, `default` + read tools (Read, Grep, Glob, NotebookRead, LS) within cwd or allowed dirs, `plan` + read tools. If Claude Code would auto-allow, the hook lets the call through without prompting. Otherwise, overlay.

**Known limitations.**

* The mode-based auto-allow replication is best-effort and errs on the conservative side. Claude Code resolves symlinks (`realpathSync`) and honors sandbox allowlists and internal-path predicates. The hook uses literal `$CWD/` prefix match, checks `allowed_dirs` (imported from Claude Code's `additionalAllowedWorkingDirs` via bootstrap), and explicitly rejects `/../` traversal. Net effect: some calls Claude Code would auto-allow fall through to the overlay anyway (extra prompt, safe direction). No false auto-allows across the other direction.
* The overlay relies on your terminal multiplexer's popup API. In screen or plain bash without any multiplexer the hook falls through to the native dialog every time. That is fine. The overlay is a UX layer, not a policy layer.
* Each overlay prompt has a 60-second timeout (`PASSTHRU_OVERLAY_TIMEOUT`, configurable). If you leave the popup idle for longer, the hook treats the prompt as cancelled and hands off to the native dialog.

## Compound command splitting

Bash commands containing pipes, logical operators, or semicolons are split into segments before matching. Each segment is matched independently against your rules.

```
echo hello && rm -rf /          # split into: ["echo hello", "rm -rf /"]
cat file.txt | head -n 10       # split into: ["cat file.txt", "head -n 10"]
ls > /tmp/out                   # split into: ["ls"] (redirections stripped)
echo 'foo && bar'               # single segment (quoted operators preserved)
```

Matching rules for compound commands:

* **Deny** on ANY segment blocks the whole command. A deny rule matching `^rm` on the second segment of `echo hello && rm -rf /` denies the entire command.
* **Allow** requires ALL segments to match. Different segments may match different allow rules. If any segment has no matching allow rule, the command falls through to the overlay.
* **Ask** on ANY segment (with no deny) triggers ask for the whole command.

The splitter respects single quotes, double quotes, `$()` subshells, backticks, and backslash escaping. Parse failures (unterminated quotes, etc.) fall back to treating the whole command as a single segment, preserving the pre-split behavior.

## Read-only command auto-allow

Common read-only Bash commands are auto-allowed without explicit rules when their path arguments stay inside the working directory or configured allowed directories. This runs after deny checking (deny always wins) and before allow/ask rule matching.

Auto-allowed commands include: `cat`, `head`, `tail`, `wc`, `stat`, `ls`, `diff`, `du`, `df`, `realpath`, `readlink`, `basename`, `dirname`, `find` (without `-exec`/`-delete`), `jq` (without `-f`/`--from-file`), `echo` (without `$`/backticks), `docker ps`, `docker images`, and more. The full list mirrors Claude Code's `readOnlyValidation.ts`.

**Path validation.** After a command matches the readonly pattern, all absolute path arguments are checked:

* Absolute paths starting with `/` must be inside cwd or an `allowed_dirs` entry.
* Relative paths (no leading `/`) are assumed to resolve inside cwd and are allowed.
* Flag arguments (starting with `-`) are skipped.

Examples:

```
cat src/main.rs                 # auto-allowed (relative path)
cat /Users/me/project/file.txt  # auto-allowed when cwd is /Users/me/project
cat /etc/passwd                 # NOT auto-allowed (outside cwd)
cat file.txt | head -n 10       # auto-allowed (both segments readonly, relative paths)
cat file.txt | rm -rf /         # NOT auto-allowed (rm is not readonly)
```

A deny rule always overrides readonly auto-allow. If you deny `^cat`, then `cat src/main.rs` is denied even though `cat` is readonly.

## Ask rules

`ask[]` is a third rule list, alongside `allow[]` and `deny[]`, that explicitly routes a matching tool call to a prompt. Use ask when you want to be asked, not when you want to auto-allow or auto-deny.

**Schema.** Ask rules live on v2 files:

```json
{
  "version": 2,
  "ask": [
    { "tool": "WebFetch", "match": { "url": "^https?://internal\\." }, "reason": "prompt for internal urls" }
  ]
}
```

The rule shape is identical to allow/deny. Only the list name changes. See [`docs/rule-format.md`](docs/rule-format.md) for the full schema.

**When a match fires.** The hook signals "ask the user". With the overlay enabled (and a supported multiplexer available), the overlay dialog pops up. With the overlay disabled or the multiplexer absent, the hook emits `permissionDecision: "ask"` and Claude Code shows its native dialog. Either way the call is paused until you decide.

**Three common use cases.**

1. **Prompt before fetching from non-allowlisted domains.** You have a blanket `WebFetch` allow, but a few domains you always want to eyeball:

   ```
   /passthru:add --ask user WebFetch "^https?://(?!example\\.com)" "prompt for non-example-domain URLs"
   ```

2. **Prompt before reading outside the project directory.** Narrow allow for your workspace paths paired with an ask rule that catches anything outside:

   ```
   /passthru:add --ask user Read "^/Users/.*/\\.ssh" "prompt before reading anything under .ssh"
   ```

3. **Prompt before MCP calls from untrusted servers.** You trust `mcp__gemini-cli__*` outright but want to audit calls to a half-trusted MCP server:

   ```
   /passthru:add --ask user '^mcp__untrusted__' "prompt on all calls to the untrusted MCP server"
   ```

**Decision order with allow + ask.** `deny` wins globally. Between `allow` and `ask`, document order within the merged list decides: a narrow `allow: Bash(git)` declared before a broader `ask: Bash(.*)` wins over the ask, and a narrow `ask: Bash(git push)` declared before a broader `allow: Bash(.*)` wins over the allow. Both are "this call is OK to consider" signals, so you get to pick the ordering in the file. See [`docs/rule-format.md`](docs/rule-format.md) for the full semantics.

## Verifier standalone

The verifier can be run without Claude Code attached:

```
bash scripts/verify.sh [--scope user|project|all] [--strict] [--format plain|json] [--quiet]
```

Exit codes:

* `0` - clean (no errors, no warnings, or warnings without `--strict`).
* `1` - one or more errors (bad JSON, schema violation, invalid regex, allow+deny conflict).
* `2` - warnings only (duplicates, shadowing) and `--strict` is set.

## Verifying rules

Run `/passthru:verify` (or `bash scripts/verify.sh`) whenever you edit a `passthru.json` file by hand. The hook silently skips malformed rule files at runtime so a typo can quietly disable your rules. The verifier surfaces the failure up front.

Automatic verification already covers every machine-driven write path. The following all call `scripts/write-rule.sh`, which takes a backup, writes the rule, runs the verifier, and restores the backup if verification fails:

* `/passthru:add` slash command
* `/passthru:suggest` slash command
* `scripts/bootstrap.sh --write`

So the only time you need to run the verifier manually is after editing `passthru.json` with an editor.

Interpret the output as follows:

* `[OK] N rules across M files checked` - nothing to do.
* `[ERR] <file>:<jq-path> [rule N] <msg>` - fix the listed file and re-run.
* `[WARN] ...` - duplicates or shadowing. Harmless by default. Add `--strict` to treat as errors.

## Test locally

To iterate on the plugin without installing it through the marketplace, load it straight from a working directory:

```
claude --plugin-dir /path/to/claude-passthru
```

This is the fastest dev loop. Every time you restart Claude Code the plugin is re-read from disk. No `/plugin install`, no cache flush, no uninstall step between iterations.

**Heads-up:** the plugin self-allow regex matches the canonical marketplace install path (`~/.claude/plugins/.../claude-passthru/scripts/<name>.sh`). When you load the plugin via `--plugin-dir` from a clone elsewhere on disk, that regex does not match, and slash commands like `/passthru:add` will hit the native permission dialog the first time. Either accept the dialog once per shell, or add a temporary one-line allow rule to your own `passthru.json` matching the dev path. The self-allow is intentionally narrow to prevent rogue scripts from impersonating the plugin.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full dev workflow including running tests and pipe-testing the hook.

## Audit log

The plugin can record every permission decision to a JSONL file at `~/.claude/passthru-audit.log`. Audit is **opt-in and off by default**. When disabled, the hook does a single `-e` check on the sentinel file and moves on, so there is effectively zero overhead.

**Enable:**

```
touch ~/.claude/passthru.audit.enabled
```

or

```
/passthru:log --enable
```

**Disable:**

```
rm ~/.claude/passthru.audit.enabled
```

or

```
/passthru:log --disable
```

**Log path:** `~/.claude/passthru-audit.log` (JSONL, one event per line).

**Event types.** From the `PreToolUse` hook:

* `allow` - a passthru allow rule matched, or the overlay returned `yes_once`/`yes_always`.
* `deny` - a passthru deny rule matched, or the overlay returned `no_once`/`no_always`.
* `ask` - the hook emitted `permissionDecision: "ask"` (ask rule matched + overlay disabled or unavailable, overlay launch failed, overlay cancelled, or unknown verdict). Claude Code's native dialog handles the prompt; `PostToolUse` classifies the outcome into an `asked_*` event.
* `passthrough` - no rule matched. The call was passed through to the native permission system, or mode auto-allow handled it.

Each log line also carries a `source` field that attributes the decision:

* `passthru` (default) - rule-driven decision or plugin self-allow.
* `overlay` - the overlay dialog emitted the verdict (`yes_once`, `no_once`, `yes_always`, `no_always`).
* `passthru-mode` - permission-mode auto-allow short-circuit (`bypassPermissions`, `acceptEdits` inside cwd, `default` + read tool inside cwd, `plan` + read tool).

From the `PostToolUse` hook, classifying what the native dialog decided for a passthrough:

* `asked_allowed_once` - user picked "allow once" in the native dialog.
* `asked_allowed_always` - user picked "allow always" (native `settings.json` got a new entry).
* `asked_denied_once` - user denied once.
* `asked_denied_always` - user denied permanently.
* `asked_allowed_unknown` - outcome could not be classified (e.g. session ended mid-dialog).

From the `PostToolUseFailure` hook, which Claude Code routes failed tool calls through (non-zero outcomes, permission refusals, runtime errors, interrupts, timeouts):

* The `asked_denied_*` events above are also emitted from this path when the failure's `error` field carries a permission-denied token (`permission denied`, `access denied`, `not allowed`, `blocked`, `denied`).
* `errored` - non-permission tool failure. The log line carries an `error_type` field when CC provides one, otherwise synthesizes `timeout` or `interrupted` from the envelope flags.

**View the log:**

```
/passthru:log
/passthru:log --since 1h --event '^asked_'
bash scripts/log.sh --format raw | jq .
```

**Rotation.** None built in. The audit file grows one line per tool call when enabled. Use `logrotate`, `cron`-driven `truncate`, or manually rotate when it gets large.

## Troubleshooting

* **Disable every rule without uninstalling.** `touch ~/.claude/passthru.disabled` turns the plugin into a no-op (the hook sees the sentinel and returns passthrough immediately). Remove the file to re-enable.
* **Bad rules after a manual edit.** Run `/passthru:verify` or `bash scripts/verify.sh` to see exactly which file, path, and message failed.
* **Rules are not firing.** Launch Claude Code with `claude --debug` and watch the hook output. The handler prints its decision reason to stderr, which `--debug` surfaces.
* **Concurrent writes or a stuck lock.** `scripts/write-rule.sh` serializes writers under a single user-scope lock at the directory `~/.claude/passthru.write.lock.d`. The lock uses `mkdir`, which is atomic on every POSIX filesystem, so no `flock(1)` is required. If the process that held the lock died without releasing it, remove the directory manually (`rmdir ~/.claude/passthru.write.lock.d`). Lock-acquisition timeout defaults to 5 seconds and can be overridden via `PASSTHRU_WRITE_LOCK_TIMEOUT=<seconds>` in the environment.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the dev loop, test commands, and rule schema evolution policy.

## License

[MIT](LICENSE)
