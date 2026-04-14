# Manual verification - /passthru:suggest

This is a checklist for humans. It is NOT executed by the bats suite. Run
these steps in a live Claude Code session to verify the slash command works
end-to-end. The automated bats tests only cover the markdown frontmatter
shape; behavioural verification lives here.

## Prerequisites

- Repo checked out at `/Users/nemirovsky/Developer/claude-passthru`.
- `jq` and `bash` available on `PATH`.
- `bats-core` installed (only needed for the automated suite).
- Clean or known baseline state in `~/.claude/passthru.json` (so you can
  tell a new rule was added).

## 1. Load the plugin from the working tree

```bash
claude --plugin-dir /Users/nemirovsky/Developer/claude-passthru
```

This loads the plugin without requiring a `/plugin install` step. From here
every step runs inside the Claude session.

## 2. Trigger a native permission prompt

Inside the session, ask Claude to run:

```
gh api /repos/anthropics/claude-code/forks
```

**Expected:**

- Claude proposes the `Bash` tool call.
- The native permission dialog fires (no matching passthru rule exists).
- Answer "yes, once". The call runs and returns JSON from the GitHub API.

## 3. Invoke /passthru:suggest with no arguments

Inside the same session:

```
/passthru:suggest
```

**Expected:**

- Claude identifies the `gh api /repos/anthropics/claude-code/forks` call
  as the most recent prompt-triggering tool call.
- Claude proposes a rule resembling:

  ```json
  {
    "tool": "Bash",
    "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" },
    "reason": "github forks api reads"
  }
  ```

  (Exact reason may vary; the regex shape is what matters.)
- Claude explains the regex: why `^` is pinned, why `[^/]+` replaces the
  owner/repo, why `forks` is the stable tail.
- Claude lists 2-3 matching examples and 2-3 near-miss non-matching examples.
- Claude mentions the narrow-vs-permissive tradeoff.
- Claude asks for: scope (`user` or `project`), allow/deny, and final
  confirmation before writing.

## 4. Confirm and write

Answer:

- Scope: `user`.
- List: `allow`.
- Confirm: yes.

**Expected:**

- Claude runs
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/write-rule.sh user allow '<rule_json>'`.
- Exit code 0.
- `~/.claude/passthru.json` now contains the proposed rule in `.allow[]`.
- Claude prints a short confirmation and reads the file back.

## 5. Confirm the rule auto-allows

Ask Claude to run the same `gh api /repos/anthropics/claude-code/forks`
command again (or a variant with a different owner/repo that still matches
the regex, e.g. `gh api /repos/cli/cli/forks`).

**Expected:**

- No native permission dialog.
- Transcript view shows the `passthru allow:` decision with the rule's
  reason.

## 6. /passthru:verify reports clean

```
/passthru:verify
```

**Expected:**

- Verifier exits 0, output shows no errors for the new rule.

## 7. Hint-driven suggest (non-default target)

Trigger a second tool call you'd like a rule for, e.g. a `WebFetch` to
`https://api.github.com/repos/anthropics/claude-code`. Accept it once via
the native dialog.

Then, with another unrelated tool call fresh on the transcript:

```
/passthru:suggest WebFetch
```

or

```
/passthru:suggest api.github.com
```

**Expected:**

- Despite a more recent tool call being present, Claude picks the
  `WebFetch` to `api.github.com` because of the hint.
- Proposed rule resembles
  `{ "tool": "WebFetch", "match": { "url": "^https?://api\\.github\\.com(/|$)" } }`.

## 8. MCP namespace suggestion

If you have an MCP server installed (e.g., `mcp__gemini-cli__ask-gemini`),
trigger one of its tools and accept via native dialog. Then:

```
/passthru:suggest mcp__gemini-cli__
```

**Expected:**

- Claude proposes a namespace rule like
  `{ "tool": "^mcp__gemini-cli__", "reason": "gemini mcp server" }` with
  no `match` block.
- After confirmation, the rule is written to the chosen scope file.

## 9. Negative - no recent tool call, no hint

In a fresh session with no prior tool calls:

```
/passthru:suggest
```

**Expected:**

- Claude reports it cannot find a candidate and asks the user to either
  trigger a tool call or supply a hint. It does NOT invoke `write-rule.sh`.

## 10. Negative - invalid regex proposed, user insists

(Simulated by editing Claude's proposed regex to something invalid like
`[` before confirming.)

**Expected:**

- `write-rule.sh` verifier rejects; stderr is surfaced verbatim.
- `~/.claude/passthru.json` is unchanged from before the attempt.

## 11. Cleanup

After the manual run, remove the test rules added above:

```bash
jq '.allow = [] | .deny = []' ~/.claude/passthru.json > ~/.claude/passthru.json.tmp \
  && mv ~/.claude/passthru.json.tmp ~/.claude/passthru.json
rm -f .claude/passthru.json
```
