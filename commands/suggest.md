---
description: Suggest a regex passthru rule from a recent tool call
argument-hint: "[tool-or-command-hint]"
---

# /passthru:suggest

Propose a passthru regex rule generalized from a recent tool call. Use this
after a native permission dialog fires for a tool call you want to auto-allow
(or auto-deny) going forward, without hand-editing `passthru.json`.

The plugin's `PreToolUse` hook evaluates passthru rules on every tool call and
auto-allows or auto-denies matching calls. This command proposes a rule,
explains the regex, shows matched/non-matched examples, and on your
confirmation hands the rule off to `scripts/write-rule.sh` (the same atomic
write path used by `/passthru:add`).

## What you must do

You are Claude. Treat `$ARGUMENTS` as an optional hint and drive the workflow
below. Do not invent behaviour. Do not silently skip steps. Surface errors
verbatim.

### 1. Identify the target tool call

If `$ARGUMENTS` is non-empty, use it as a hint. The hint may be any of:

- a tool name (e.g., `Bash`, `WebFetch`, `Read`, `mcp__gemini-cli__ask-gemini`)
- a command fragment (e.g., `gh api`, `git push`)
- a URL or URL fragment (e.g., `https://api.github.com/`)
- a file path fragment (e.g., `/Users/nemirovsky/Developer/`)

Scan recent turns in the conversation transcript, most recent first, and
pick the first tool call that matches the hint. Prefer tool calls where a
native permission dialog fired (the user was prompted to allow/deny).

If `$ARGUMENTS` is empty, scan the transcript most-recent-first and pick the
most recent tool call that triggered a native permission prompt in this
session. If nothing obvious jumps out, ask the user which tool call they
want a rule for and list the last few candidate calls.

Record: `tool_name`, the relevant `tool_input` fields, and the decision
outcome if visible.

### 2. Build a regex that generalizes the call without overfitting

Goal: match *this class* of command, not only the exact one. Strip values
that will legitimately vary (owner, repo, page number, file under a
directory, minor URL path segments). Keep the stable leading portion.

Use these patterns per tool:

**Bash / PowerShell** - match on the `command` field, pinned at `^`:
- `gh api /repos/anthropics/claude-code/forks` -> `^gh api /repos/[^/]+/[^/]+/forks`
- `git push origin main` -> `^git push origin `
- `npm run test:unit -- --watch` -> `^npm run test:unit`
- Pin to `^` to prevent matching commands that merely contain the fragment.
- Replace concrete identifiers (owners, repos, branch names, version tags,
  numeric IDs) with `[^/]+`, `[^ ]+`, or `\\S+` depending on the separator.
- Do NOT include trailing arguments that vary shot-to-shot.

**Read / Edit / Write** - match on the `file_path` field:
- Use a directory prefix: `^/Users/nemirovsky/Developer/some-project/`.
- Escape literal `.` and `/` is fine as-is in POSIX ERE.
- Prefer the project root over the individual file, unless the user's hint
  asked for a single file.

**WebFetch** - match on the `url` field, pinned at `^`:
- `https://api.github.com/repos/foo/bar/issues` -> `^https?://api\\.github\\.com(/|$)`
- Anchor the scheme + host, allow any trailing path.
- For subdomain-scoped rules: `^https?://[^.]+\\.example\\.com(/|$)`.

**MCP tools** - match the `tool_name` itself (no `match` block needed):
- Single MCP tool: `^mcp__gemini-cli__ask-gemini$`.
- Whole server namespace: `^mcp__gemini-cli__` (no trailing `$`).
- Namespace rules omit the `match` object entirely - same shortcut as
  `/passthru:add`.

**Other tools** - ask the user which `tool_input` field should carry the
match before proposing a regex.

### 3. Present the proposal

Show the user, in this order:

1. The identified tool call (tool name + the key input fields, truncated).
2. The proposed rule as a JSON object, e.g.:

   ```json
   {
     "tool": "Bash",
     "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" },
     "reason": "github forks api reads"
   }
   ```

3. A plain-language explanation of what the regex matches and why each
   generalization choice was made (why `[^/]+` and not the literal owner,
   why `^` is there, etc.).
4. A "matches" section: 2-3 example commands that WILL match.
5. A "does not match" section: 2-3 similar-looking commands that will
   NOT match. Include at least one near-miss to make the boundary obvious.
6. A narrow-vs-permissive tradeoff note. If the regex is permissive
   (broad verb, open trailing path), call that out so the user can tighten
   it. If the regex is narrow (pins a specific subcommand), mention that
   they may need to add sibling rules later.

### 4. Ask the user before writing

Ask the user these three things (use `AskUserQuestion` if running in an
interactive context; otherwise ask inline and wait for a reply):

1. **Scope**: `user` (applies to every Claude Code session) or `project`
   (applies only inside the current project). Default: `user` when the
   command is clearly tool-class-wide (e.g., `gh api /repos/`), `project`
   when the regex embeds a specific project path.
2. **Allow or deny**: `allow` (default) or `deny`.
3. **Confirmation**: "write this rule?" - do not proceed on ambiguous
   answers. Re-ask or abort.

If the user wants to tweak the regex or reason, accept their edits and
re-present the proposal from step 3 before asking again.

### 5. Write the rule

On confirmation, build the final JSON with `jq -n --arg ...` (avoid string
concatenation), then run exactly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/write-rule.sh <scope> <allow|deny> '<rule_json>'
```

Single-quote the rule JSON. Do not interpolate the JSON into the shell any
other way.

### 6. Handle the result

- **Exit code 0:** print a short confirmation identifying the scope and
  list (e.g., `added to user allow list`), then read the target file back
  via the `Read` tool and show its contents.
  - User scope target: `~/.claude/passthru.json`.
  - Project scope target: `.claude/passthru.json` in the current working
    directory.
- **Non-zero exit code:** surface the `stderr` output verbatim. Do not
  paraphrase. The verifier rejects invalid regex, schema violations, and
  cross-scope conflicts; the wrapper has already restored the backup.
  Suggest the user re-run `/passthru:verify` for a full report.

## Examples

### Narrow vs permissive tradeoff

Given Bash call: `gh api /repos/anthropics/claude-code/forks`

**Narrow (recommended for starting out):**

```json
{ "tool": "Bash",
  "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" },
  "reason": "github forks api reads" }
```

Matches `gh api /repos/anthropics/claude-code/forks` and the same call for
any other `owner/repo`. Does NOT match `gh api /repos/foo/bar/issues`.
Tradeoff: if you also want `/issues`, `/pulls`, etc., you will need
sibling rules (or broaden the regex).

**Permissive:**

```json
{ "tool": "Bash",
  "match": { "command": "^gh api " },
  "reason": "all gh api reads" }
```

Matches every `gh api ...` call. Fewer rules, but grants broader access.
Use this only if you trust all `gh api` calls Claude might make.

### WebFetch, host-anchored

Given WebFetch call with `url: https://api.github.com/repos/anthropics/claude-code`:

```json
{ "tool": "WebFetch",
  "match": { "url": "^https?://api\\.github\\.com(/|$)" },
  "reason": "github api fetches" }
```

Matches any URL under `api.github.com`. Does NOT match
`https://api.github.com.evil.example` - the `(/|$)` anchor prevents that.

### MCP namespace, no match block

Given a call to `mcp__gemini-cli__ask-gemini`:

```json
{ "tool": "^mcp__gemini-cli__",
  "reason": "gemini mcp server" }
```

No `match` block - MCP-namespace rules key off `tool_name` only.
