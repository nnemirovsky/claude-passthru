---
description: Add a passthru allow, ask, or deny rule for a tool
argument-hint: "<scope> <tool> <pattern> [reason] [--deny|--ask] [--field <name>]"
---

# /passthru:add

Add a regex rule to the passthru allow, ask, or deny list for the given scope.

The plugin's `PreToolUse` hook evaluates passthru rules on every tool call and
auto-allows, routes to an ask prompt, or auto-denies matching calls, bypassing
the native permission dialog. Use this command to add a rule from within a
live session without hand-editing `passthru.json`.

## What you must do

You are Claude. Parse `$ARGUMENTS` and execute a rule-write workflow. Do not
invent behaviour beyond what is specified below. Surface errors verbatim.

### 1. Tokenize `$ARGUMENTS`

Split on shell-quoted whitespace. Keep the order intact. You will consume
tokens in this order, with three flags allowed anywhere:

- `--deny` - use the `deny` list instead of `allow` (default: `allow`).
- `--ask` - use the `ask` list instead of `allow`. Ask rules route matching
  tool calls through a permission prompt (the overlay, when enabled, or the
  native Claude Code dialog as a fallback). Mutually exclusive with `--deny`
  and `--allow`.
- `--allow` - explicit opt-in to the `allow` list. Redundant with the default
  but accepted for symmetry. Mutually exclusive with `--deny` and `--ask`.
- `--field <name>` - explicit `tool_input` field to match against. If omitted,
  use the default for the tool (see step 4 below).

If more than one of `--allow`, `--ask`, and `--deny` appears in `$ARGUMENTS`,
stop and tell the user: `--allow, --ask, and --deny are mutually exclusive`.
Do not invoke the shell.

Remaining (non-flag) tokens, in order:

1. `scope` - must be `user` or `project`.
2. `tool` - a regex matched against the `tool_name` (e.g., `Bash`,
   `Bash|PowerShell`, `^mcp__gemini-cli__`).
3. `pattern` - the main regex matched against the chosen `tool_input` field.
   This token is **omitted** only when the tool is an MCP namespace (then no
   match block is written; see step 5).
4. `reason` (optional) - one or more trailing tokens. Join them with a single
   space. If empty, omit the `reason` field from the rule JSON.

### 2. Validate scope

If the first non-flag token is not exactly `user` or `project`, stop and tell
the user: `scope must be "user" or "project" (got: <value>)`. Do not invoke
the shell.

### 3. Detect the MCP-namespace shortcut

If `tool` starts with `^mcp__` (typical MCP namespace pattern), treat the
rule as tool-namespace-only: no `match` block is written. In that case the
`pattern` token MUST be omitted, and the next token is `reason` instead. If
both a pattern and an MCP-namespace tool were provided, warn the user and
prefer the namespace-only form (drop the pattern).

### 4. Pick the default field (when `--field` is not given)

| tool regex matches            | default field |
| ----------------------------- | ------------- |
| `Bash` or `PowerShell`        | `command`     |
| `Read`, `Edit`, `Write`       | `file_path`   |
| `WebFetch`                    | `url`         |
| MCP namespace (`^mcp__`)      | (no match)    |
| anything else                 | require `--field` - if missing, stop and tell the user |

### 5. Construct the rule JSON

For regular (non-MCP-namespace) rules:

```json
{"tool": "<tool regex>", "match": {"<field>": "<pattern>"}, "reason": "<reason>"}
```

For MCP-namespace rules (no `match` block):

```json
{"tool": "<tool regex>", "reason": "<reason>"}
```

Omit the `reason` key entirely when no reason was given. Produce valid
JSON - you can use the `Bash` tool with `jq -n --arg ...` to build it
safely rather than string-concatenating.

### 6. Invoke the write wrapper

Run exactly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/write-rule.sh <scope> <allow|ask|deny> '<rule_json>'
```

Pick the list as follows:

- `--deny` present -> `deny`
- `--ask` present -> `ask`
- `--allow` present OR no flag -> `allow` (default)

Single-quote the rule JSON so the shell does not reinterpret it.

### 7. Handle the result

- **Exit code 0:** print a short confirmation identifying the scope and list
  (e.g., `added to user allow list`), then read the target file back via the
  `Read` tool and show its contents to the user.
  - User scope target: `~/.claude/passthru.json`.
  - Project scope target: `.claude/passthru.json` in the current working
    directory.
- **Non-zero exit code:** surface the `stderr` output **verbatim** to the user.
  Do not rephrase. The verifier rejects invalid regex, schema violations, and
  cross-scope conflicts; the wrapper has already restored the backup. Suggest
  the user re-run `/passthru:verify` if they want a full report.

## Examples

- Allow `gh api /repos/...` commands at the user scope:

  ```
  /passthru:add user Bash "^gh api /repos/" "github api reads"
  ```

- Allow reads anywhere under a specific project directory (explicit field):

  ```
  /passthru:add project Read "^/Users/nemirovsky/Developer/" --field file_path
  ```

- Allow an entire MCP tool namespace (no match block):

  ```
  /passthru:add user "^mcp__gemini-cli__" "gemini mcp"
  ```

- Deny `rm -rf /` across Bash and PowerShell (safety rule):

  ```
  /passthru:add --deny user "Bash|PowerShell" "rm\\s+-rf\\s+/" "safety"
  ```

- Prompt on fetches to a given domain (route to the ask list):

  ```
  /passthru:add --ask user WebFetch "^https?://unsafe\\." "prompt on this domain"
  ```
