# Rule format reference

`passthru` rule files are JSON with the shape:

```json
{
  "version": 1,
  "allow": [
    { "tool": "...", "match": { "...": "..." }, "reason": "..." }
  ],
  "deny": [
    { "tool": "...", "match": { "...": "..." }, "reason": "..." }
  ]
}
```

This document covers every field, the matching semantics, and how rule files are merged across scopes.

## Top-level fields

### `version` (integer, optional)

Schema version for the rule file. Default and current value is `1`. The verifier rejects anything else. Future breaking changes will bump this to `2`.

When a file does not include `version`, the loader treats it as `1`.

### `allow` (array, optional)

List of allow rules. When any rule in this list matches the incoming tool call (and no deny rule matches first), the hook emits an `allow` decision and Claude Code skips the native permission dialog.

### `deny` (array, optional)

List of deny rules. When any rule in this list matches, the hook emits a `deny` decision, even if a later allow rule would also match. Deny has priority over allow.

Both `allow` and `deny` default to empty arrays when missing.

## Rule object fields

Each entry in `allow[]` or `deny[]` is an object with these fields. At least one of `tool` or `match` is required.

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

## Matching semantics

When a tool call fires, the `PreToolUse` hook runs this algorithm against the merged rule set:

1. Check the emergency sentinel `~/.claude/passthru.disabled`. If present, emit passthrough immediately.
2. Iterate `deny[]` in order. The first rule whose `tool` and `match` both pass triggers a `deny` decision. The hook stops here.
3. Iterate `allow[]` in order. The first rule whose `tool` and `match` both pass triggers an `allow` decision. The hook stops here.
4. If nothing matched, emit passthrough. Claude Code then consults the native permission system.

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
* `version` is taken as `1` (current schema version).

Both scopes contribute. Neither overrides. To remove a rule from a lower-priority file you edit that file directly; there is no "override" or "mask" semantics.

## Verification

The verifier (`scripts/verify.sh`) runs these checks across the merged set:

* **parse** - every file is valid JSON.
* **schema** - every rule has `tool` or `match`, types match spec, `version` is `1`.
* **regex** - every regex compiles in perl.
* **duplicates** - same `tool + match` identity appears in multiple files or lists. Warning.
* **conflict** - identical `tool + match` appears in both `allow[]` and `deny[]` post-merge. Error.
* **shadowing** - within one merged `allow[]` or `deny[]`, a later rule duplicates an earlier one. Warning.

See [`CLAUDE.md`](../CLAUDE.md) section "Verifier CLI flags" for the exact flags and exit codes.
