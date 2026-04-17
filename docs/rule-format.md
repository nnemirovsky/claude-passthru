# Rule format reference

`passthru` rule files are JSON with the shape:

```json
{
  "version": 2,
  "allow": [
    { "tool": "...", "match": { "...": "..." }, "reason": "..." }
  ],
  "deny": [
    { "tool": "...", "match": { "...": "..." }, "reason": "..." }
  ],
  "ask": [
    { "tool": "...", "match": { "...": "..." }, "reason": "..." }
  ]
}
```

This document covers every field, the matching semantics, and how rule files are merged across scopes.

## Top-level fields

### `version` (integer, optional)

Schema version for the rule file. Accepted values are `1` and `2`. The verifier rejects anything else. Future breaking changes will bump this to `3`.

When a file does not include `version`, the loader treats it as `1`.

Schema v2 adds the optional `ask[]` array at the top level. Everything else is unchanged between v1 and v2, so v1 files continue to work without modification. v2 files that do not declare `ask[]` behave identically to v1 files.

**v1 -> v2 upgrade trigger.** `scripts/write-rule.sh` upgrades a file from `version: 1` to `version: 2` in-place the first time an `ask` write lands on it (for example, when you run `/passthru:add --ask ...`). Before that moment your file stays at `version: 1` and the loader keeps treating it as v1. Allow and deny writes do not upgrade the version; only `ask` writes flip the flag. The upgrade preserves any arbitrary extra top-level keys your file may carry and is covered by `tests/write_rule.bats`.

### `allow` (array, optional)

List of allow rules. When any rule in this list matches the incoming tool call (and no deny rule matches first), the hook emits an `allow` decision and Claude Code skips the native permission dialog.

### `deny` (array, optional)

List of deny rules. When any rule in this list matches, the hook emits a `deny` decision, even if a later allow or ask rule would also match. Deny has priority over everything else.

### `ask` (array, optional, v2 only)

List of ask rules. When any rule in this list matches (and no deny rule matches first), the hook signals "ask the user before running". This is the passthru equivalent of Claude Code's native `permissionDecision: "ask"` behavior. With the overlay enabled (the default on supported terminals), the overlay dialog fires. With the overlay disabled or unavailable, the hook falls through so Claude Code shows its native permission dialog.

Use `ask[]` when you want explicit prompts for a tool call rather than either silent allow or silent deny. Common cases:

* Domains you want to double-check before each fetch (`WebFetch` for internal services).
* `Bash` commands that are *sometimes* fine but you want a manual sanity check (anything that touches production).
* MCP tools that mix safe and risky operations and cannot be split cleanly into allow-only and deny-only patterns.

`ask` rules share the same shape as `allow` and `deny` rules. They only exist on v2 files. A file that declares `version: 1` with an `ask[]` key has that key silently ignored by the loader (so partial migrations do not fail loud). The verifier only validates `ask[]` contents on files that declare `version: 2`.

All of `allow`, `deny`, and `ask` default to empty arrays when missing.

### `allowed_dirs` (array, optional)

Array of absolute directory paths that extend the set of trusted locations for path-based auto-allow checks. When present, Read/Edit/Write/Grep/Glob/LS tools operating on files inside any `allowed_dirs` entry are treated the same as files inside the working directory for mode-based auto-allow. Read-only Bash commands (`cat`, `head`, `ls`, etc.) also check `allowed_dirs` when validating absolute path arguments.

```json
{
  "version": 2,
  "allowed_dirs": ["/opt/shared-data", "/home/user/reference"],
  "allow": [],
  "deny": [],
  "ask": []
}
```

Both authored and imported rule files may declare `allowed_dirs`. During loading, arrays from all four rule files are concatenated and deduplicated. Bootstrap imports Claude Code's `additionalAllowedWorkingDirs` from `settings.json` and writes them to `allowed_dirs` in `passthru.imported.json`.

Each entry must be a non-empty string. Paths containing `/../` (path traversal) are rejected by the verifier. Files without `allowed_dirs` are backward compatible (treated as an empty array).

## Rule object fields

Each entry in `allow[]`, `deny[]`, or `ask[]` is an object with these fields. At least one of `tool` or `match` is required.

### `tool` (string, optional)

Regex matched against the tool name (`tool_name` in the hook payload). Examples of tool names Claude Code produces:

* `Bash`, `PowerShell`
* `Read`, `Write`, `Edit`
* `WebFetch`, `WebSearch`
* `mcp__<server>__<tool>` for MCP tools (e.g. `mcp__gemini-cli__ask-gemini`)

The pattern is treated as a PCRE-compatible regex. No implicit anchoring is added. `Bash` on its own matches any tool name containing the substring `Bash`. Anchor explicitly to pin the match:

* `^Bash$` - match the `Bash` tool exactly.
* `^mcp__gemini-cli__` - match any tool on the `gemini-cli` MCP server.
* `Bash|PowerShell` - match either shell tool.

Absent `tool` (or an empty string) matches any tool.

### `match` (object, optional)

Object keyed by `tool_input` field names. Each value is a PCRE-compatible regex that must match the corresponding input field's string value.

Common `tool_input` field names:

* `Bash` and `PowerShell`: `command`
* `Read`, `Edit`, `Write`: `file_path`
* `WebFetch`: `url`
* MCP tools: depends on the server. Inspect a real call if you need to match sub-args.

Rules matching semantics:

* If a field named in `match` is **missing** from `tool_input`, the rule does NOT match.
* If the field is present but `null`, the rule does NOT match.
* If the field is present and a non-null string, the regex must match to pass.
* All keys in `match` must pass (AND semantics). No OR at the field level; use alternation `|` inside a single regex for OR over patterns.

Absent `match` (or an empty object) matches any input, so the rule reduces to a tool-name filter.

### `reason` (string, optional)

Human-readable note describing why the rule exists. The hook surfaces it in the `permissionDecisionReason` field Claude Code shows. Purely documentation for you. The verifier does not check it.

### `_source_hash` (string, optional)

SHA-256 hex digest of the original `permissions.allow` entry that a given rule was imported from. Present only on rules written by `scripts/bootstrap.sh`. You never need to set this by hand, and you should not edit it. The session-start bootstrap hint uses this field to compute the diff between entries in `settings.json` and rules already in `passthru.imported.json`: a rule carries `_source_hash` iff bootstrap has imported the corresponding native entry.

Legacy `passthru.imported.json` files from before this field existed have no hashes. In that case the hint re-fires every session until you re-run `/passthru:bootstrap`, which rewrites the file with hashes attached. After that the hint auto-silences as intended.

## Example rules

**Allow `gh api /repos/*/*/forks` across any owner/repo:**

```json
{
  "tool": "Bash",
  "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" },
  "reason": "github forks api reads"
}
```

**Allow a whole MCP server namespace:**

```json
{
  "tool": "^mcp__gemini-cli__",
  "reason": "gemini mcp server"
}
```

Note no `match` block. MCP-namespace rules key off `tool_name` only.

**Deny destructive patterns across any shell:**

```json
{
  "tool": "Bash|PowerShell",
  "match": { "command": "rm\\s+-rf\\s+/" },
  "reason": "safety"
}
```

The tool regex `Bash|PowerShell` matches either shell because no `^` is in front. `\\s` is JSON-escaped; inside the regex engine it becomes `\s`.

## Decision flow

One-line summary, in priority order:

**`deny` > `ask` + `allow` in document order > `allow` (generic, unanchored) > mode auto-allow > overlay prompt > native dialog (fallback).**

Read in more detail, this is the full sequence the `PreToolUse` hook follows for every tool call:

1. **Emergency kill switch.** If `~/.claude/passthru.disabled` exists, emit passthrough immediately. The hook does no further work.
2. **Deny.** Iterate `deny[]` in order. The first rule whose `tool` and `match` both pass triggers a `deny` decision. Deny is globally dominant. Nothing else in the pipeline can override it.
3. **Ask + allow, document order.** Iterate `allow[]` and `ask[]` interleaved in document order within each merged file, then across files in the fixed scope order (user authored, user imported, project authored, project imported). The first rule whose `tool` and `match` both pass wins:
   * `allow` match -> emit `allow` (Claude Code skips the dialog).
   * `ask` match -> route to the overlay (when enabled + a supported multiplexer is available) or emit `permissionDecision: "ask"` so Claude Code shows its native dialog (fallback).
4. **Mode auto-allow.** If no rule matched, replicate Claude Code's built-in permission-mode short-circuits so the overlay does not fire for calls Claude Code would auto-approve anyway:
   * `permission_mode: bypassPermissions` -> allow everything.
   * `permission_mode: acceptEdits` + tool is `Write` or `Edit` + `file_path` inside cwd (literal prefix, no `/../`) -> allow.
   * `permission_mode: default` (or absent) + tool is `Read` + `file_path` inside cwd -> continue (Claude Code auto-allows on its side).
   * `permission_mode: plan` -> continue (plan-mode logic handles it).
5. **Overlay.** If the prior steps do not emit a decision, the hook checks the overlay sentinel and multiplexer detection.
   * Sentinel `~/.claude/passthru.overlay.disabled` present -> emit `permissionDecision: "ask"` and let Claude Code show its native dialog.
   * No supported multiplexer detected -> same fallback.
   * Multiplexer available and overlay enabled -> launch the popup and consume the verdict:
      * `yes_once` -> allow.
      * `no_once` -> deny.
      * `yes_always` -> write an `allow` rule via `write-rule.sh`, emit allow.
      * `no_always` -> write a `deny` rule, emit deny.
      * `cancel` / timeout / error -> emit `permissionDecision: "ask"`; native dialog picks up.
6. **Native fallback.** If the overlay was unavailable, disabled, or cancelled, Claude Code's built-in permission dialog handles the prompt. The PostToolUse hook classifies the outcome into the `asked_*` audit events.

Step 3 is where ask and allow tie-break by document order, not by list name. A narrow `allow: Bash(git)` declared before a broader `ask: Bash(.*)` correctly wins over the ask. Likewise, a narrow `ask: Bash(git push)` declared before a broader `allow: Bash(.*)` correctly wins over the allow. Both are "this call is OK to consider" signals, so the user-provided file order is the tie-breaker.

## Matching semantics

The decision flow above is the full algorithm. Per-rule matching (the `tool + match` check used in steps 2 and 3) works as follows.

"Tool and match both pass" means:

* If `tool` is present, its regex must match `tool_name`.
* If `match` is present, every key in it must exist in `tool_input`, be non-null, and its regex must match.
* Missing `tool` = match any tool. Missing `match` = match any input.

Regex compilation errors at match time do NOT crash the hook; they skip the offending rule and continue. The verifier catches these eagerly so they never reach the hot path.

## Merge semantics across scopes

The hook loads up to four rule files, in this fixed order:

1. `~/.claude/passthru.json` - user, hand-authored.
2. `~/.claude/passthru.imported.json` - user, from `bootstrap.sh`.
3. `<project>/.claude/passthru.json` - project, hand-authored.
4. `<project>/.claude/passthru.imported.json` - project, from `bootstrap.sh`.

Any subset may exist. Missing files are treated as `{}`. Malformed files fail loud in the verifier and silently in the hook (fail-open).

Merge rule:

* The `allow[]` arrays from all four files are concatenated in the order above.
* The `deny[]` arrays from all four files are concatenated in the order above.
* The `ask[]` arrays from all four files are concatenated in the order above. Files that declare `version: 1` contribute an empty `ask[]` (the key is v2-only, even if the file happens to include one it is ignored by the loader).
* The merged document is always emitted as `version: 2` since v2 is a strict superset of v1.

Both scopes contribute. Neither overrides. To remove a rule from a lower-priority file you edit that file directly; there is no "override" or "mask" semantics.

## Verification

The verifier (`scripts/verify.sh`) runs these checks across the merged set:

* **parse** - every file is valid JSON.
* **schema** - every rule has `tool` or `match`, types match spec, `version` is `1` or `2`. On v2 files, `ask[]` is validated with the same rule-shape checks as `allow[]` and `deny[]`.
* **regex** - every regex compiles in perl.
* **duplicates** - same `tool + match` identity appears in multiple files or lists (same list name repeated). Warning.
* **conflict** - identical `tool + match` appears in two or more of (`allow[]`, `deny[]`, `ask[]`) post-merge. Error.
* **shadowing** - within one merged `allow[]`, `deny[]`, or `ask[]`, a later rule duplicates an earlier one. Warning.

See [`CLAUDE.md`](../CLAUDE.md) section "Verifier CLI flags" for the exact flags and exit codes.
