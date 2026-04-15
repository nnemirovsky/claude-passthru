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
* **Shape-aware path and URL rules.** Match on the structure of a path or URL (e.g. `^gh api /repos/[^/]+/[^/]+/forks`) so you pin the endpoint, not the owner.
* **MCP tool namespaces.** Allow a whole MCP server family with a single tool-regex rule, no need to enumerate every tool.
* **Deny lists that win.** A matching deny rule unconditionally overrides any allow, so you can cement safety rules on top of a permissive allow set.
* **Opt-in audit log.** JSONL record of every decision (including what the native dialog did for passthroughs). Off by default, zero overhead when disabled.
* **Standalone verifier.** Validate every rule file from the command line or via `/passthru:verify` to catch bad JSON, invalid regex, and allow/deny conflicts before they silently disable rules.
* **First-run bootstrap.** One-shot `/passthru:bootstrap` command (or `scripts/bootstrap.sh` for scripting) that converts existing native `permissions.allow` entries into passthru rules. A one-time `SessionStart` hint points at it when there are importable entries.

## Commands

All commands are plugin-namespaced under `/passthru:`.

| Command | What it does |
| --- | --- |
| `/passthru:bootstrap` | One-shot importer: reviews your existing `permissions.allow` entries, shows the proposed rules, asks to confirm, then writes `passthru.imported.json`. Runs the verifier afterwards. |
| `/passthru:add` | Add a rule without hand-editing `passthru.json`. Supports `--deny` and `--field`. |
| `/passthru:suggest` | Propose a generalized rule from a recent tool call in the conversation, then write it on confirmation. |
| `/passthru:verify` | Validate every rule file. Surfaces parse errors, schema violations, invalid regex, duplicates, and allow/deny conflicts. |
| `/passthru:log` | Read the audit log with filters. Also toggles the audit sentinel on/off. |

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

Bootstrap writes to dedicated imported files so hand-curated rules in `passthru.json` stay separate:

* `~/.claude/passthru.imported.json` (user scope)
* `.claude/passthru.imported.json` (project scope)

Re-running bootstrap overwrites the imported files. Edit `passthru.json` (the authored file) for hand-managed rules. Both files are merged at hook time.

**One-time session hint.** The plugin also ships a `SessionStart` hook that detects when you have importable `permissions.allow` entries but no passthru rule files yet. On the first such session it prints a single-line hint to stderr pointing at `/passthru:bootstrap`, then records a marker at `~/.claude/passthru.bootstrap-hint-shown` so the hint never fires again. Delete that marker file to re-enable the hint.

## Rule format reference

Rule files are JSON with the shape:

```json
{
  "version": 1,
  "allow": [ { "tool": "...", "match": { "...": "..." }, "reason": "..." } ],
  "deny":  [ { "tool": "...", "match": { "...": "..." }, "reason": "..." } ]
}
```

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

* `allow` - a passthru allow rule matched.
* `deny` - a passthru deny rule matched.
* `passthrough` - no passthru rule matched. Control passed to the native permission system.

From the `PostToolUse` hook, classifying what the native dialog decided for a passthrough:

* `asked_allowed_once` - user picked "allow once" in the native dialog.
* `asked_allowed_always` - user picked "allow always" (native `settings.json` got a new entry).
* `asked_denied_once` - user denied once.
* `asked_denied_always` - user denied permanently.
* `asked_allowed_unknown` - outcome could not be classified (e.g. session ended mid-dialog).

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
