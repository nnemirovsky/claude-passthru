# passthru

Regex-based permission rules for Claude Code via `PreToolUse` hook.

`passthru` supplements the native permission system with regex rules that the native glob syntax cannot express. The hook reads merged user-scope and project-scope rule files and returns allow or deny decisions, bypassing the native permission dialog on match and falling through to it on miss. Works across every tool Claude Code exposes (`Bash`, `PowerShell`, `Read`, `Edit`, `Write`, `WebFetch`, MCP tools, and so on).

## Motivating examples

Two gaps the native permission system cannot close on its own.

**1. Directory-prefix Bash rules.** A native rule like `Bash(bash /Users/you/project/:*)` cannot match `bash /Users/you/project/script.sh` because Claude Code enforces a word boundary after the prefix (see `src/tools/BashTool/bashPermissions.ts:894-911`). Glob wildcards only apply at the end, so you either have to list every script by name or grant the whole `Bash(bash:*)` namespace. A passthru rule does what you wanted in the first place:

```json
{ "tool": "Bash", "match": { "command": "^bash /Users/you/project/" }, "reason": "run project scripts" }
```

**2. Shape-aware command rules.** Native `Bash(gh api:*)` either allows every `gh api` call or none. A passthru rule pins the shape of the endpoint you want to auto-allow:

```json
{ "tool": "Bash", "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" }, "reason": "github forks api reads" }
```

This matches `gh api /repos/anthropics/claude-code/forks` for any owner/repo pair but does NOT match `gh api /repos/foo/bar/issues`, `curl ...`, or `git push`.

See [`docs/examples.md`](docs/examples.md) for more real-world rules covering `Bash`, `PowerShell`, `Read`, `WebFetch`, and MCP tool namespaces.

## Why

Native rules solve the common case. They fall short when:

* The thing you want to match is not space-delimited after a prefix (directory paths, URL paths).
* You need to pin the shape of a sub-argument, not just the leading verb.
* You want to allow a whole MCP server family without listing every tool.
* You want a deny list that unconditionally overrides a more permissive allow.

`passthru` adds a thin regex layer in front of the native system. When a passthru rule matches, the hook emits a decision and Claude Code skips the permission dialog. When nothing matches, control passes through to the native rules unchanged. Nothing about your existing `settings.json` or `.claude/settings.local.json` changes.

## Install

```
/plugin marketplace add nemirovsky/claude-passthru
/plugin install passthru
```

You can also load the plugin straight from a working tree for local testing:

```
claude --plugin-dir /path/to/claude-passthru
```

That form is handy during development because no `/plugin install` step is needed. See the [Test locally](#test-locally) section below.

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

## First-run bootstrap

The plugin ships a bootstrap script that converts existing native `permissions.allow` entries from `settings.json` files into passthru rule files. Run it once after install to avoid starting from zero.

Dry run first (prints proposed rules to stdout, writes nothing):

```
bash ~/.claude/plugins/marketplaces/nemirovsky/claude-passthru/scripts/bootstrap.sh
```

The exact path depends on where Claude Code installed the plugin. If you cloned the repo directly, the script lives at `scripts/bootstrap.sh` in your clone. Inspect the output, then re-run with `--write` to persist:

```
bash .../scripts/bootstrap.sh --write
```

`--write` mode also runs `scripts/verify.sh --quiet` after writing. If the verifier finds errors, the script restores the pre-write backup and exits non-zero.

Bootstrap writes to dedicated imported files so hand-curated rules in `passthru.json` stay separate:

* `~/.claude/passthru.imported.json` (user scope)
* `.claude/passthru.imported.json` (project scope)

Re-running bootstrap overwrites the imported files. Edit `passthru.json` (the authored file) for hand-managed rules. Both files are merged at hook time.

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

Run `/passthru:verify` (or `bash scripts/verify.sh`) whenever you edit a `passthru.json` file by hand. The hook silently skips malformed rule files at runtime so a typo can quietly disable your rules; the verifier surfaces the failure up front.

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
* `passthrough` - no passthru rule matched; control passed to the native permission system.

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
* **Concurrent writes or a stuck lock.** `scripts/write-rule.sh` serializes writers under a single user-scope lock at `~/.claude/passthru.write.lock` (with `flock(1)` when available) or the directory `~/.claude/passthru.write.lock.d` (mkdir-based fallback on systems without `flock`). If the process that held the lock died without releasing it, remove that file or directory manually. Lock-acquisition timeout defaults to 5 seconds and can be overridden via `PASSTHRU_WRITE_LOCK_TIMEOUT=<seconds>` in the environment.

## License

MIT
