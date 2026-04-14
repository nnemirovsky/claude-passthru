# Manual verification - /passthru:add

This is a checklist for humans. It is NOT executed by the bats suite. Run
these steps in a live Claude Code session to verify the slash command works
end-to-end. The automated bats tests only cover the markdown frontmatter
shape; behavioural verification lives here.

## Prerequisites

- Repo checked out at `/Users/nemirovsky/Developer/claude-passthru`.
- `jq` and `bash` available on `PATH`.
- `bats-core` installed (only needed for the automated suite).

## 1. Load the plugin from the working tree

```bash
claude --plugin-dir /Users/nemirovsky/Developer/claude-passthru
```

This loads the plugin without requiring a `/plugin install` step. From here
every step runs inside the Claude session.

## 2. Happy path - add a user-scope allow rule

Inside the session:

```
/passthru:add user Bash "^gh api /repos/" "github api reads"
```

**Expected:**

- Claude constructs a rule JSON and shells out to
  `bash ${CLAUDE_PLUGIN_ROOT}/scripts/write-rule.sh user allow '<json>'`.
- Exit code 0.
- `~/.claude/passthru.json` exists and contains the new rule in `.allow[]`:

  ```json
  {
    "version": 1,
    "allow": [
      {
        "tool": "Bash",
        "match": { "command": "^gh api /repos/" },
        "reason": "github api reads"
      }
    ],
    "deny": []
  }
  ```
- Claude prints a short confirmation and shows the resulting file contents.

## 3. Confirm matching command is auto-allowed

Still inside the session, run:

```
!gh api /repos/anthropics/claude-code
```

(Or ask Claude to run it via the `Bash` tool.)

**Expected:**

- No native permission dialog appears.
- Transcript view shows `passthru allow: github api reads` as the decision
  reason for this Bash call.

## 4. Project-scope rule (explicit field)

```
/passthru:add project Read "^/Users/nemirovsky/Developer/" --field file_path
```

**Expected:**

- `.claude/passthru.json` (in the current project cwd) now has a Read rule
  matching `file_path`.
- Reading a file under `/Users/nemirovsky/Developer/...` is auto-allowed
  (`passthru allow:` in transcript) without a native prompt.

## 5. MCP namespace rule (no match block)

```
/passthru:add user "^mcp__gemini-cli__" "gemini mcp"
```

**Expected:**

- New rule in `~/.claude/passthru.json` with `"tool": "^mcp__gemini-cli__"`,
  no `match` field, `reason: "gemini mcp"`.

## 6. Deny rule

```
/passthru:add --deny user "Bash|PowerShell" "rm\\s+-rf\\s+/" "safety"
```

**Expected:**

- Rule appended to `.deny[]`, not `.allow[]`, in `~/.claude/passthru.json`.
- Running `rm -rf /anything` via Bash is auto-denied with
  `passthru deny:` in the transcript.

## 7. Negative - invalid regex rejected

```
/passthru:add user Bash "["
```

**Expected:**

- Verifier rejects the unclosed character class.
- `write-rule.sh` restores the backup.
- Exit code non-zero; Claude surfaces the verifier's stderr verbatim.
- `~/.claude/passthru.json` is unchanged and **not corrupted** (still
  parses as JSON, still contains whatever rules existed before this call).

## 8. Negative - bad scope

```
/passthru:add global Bash "^foo"
```

**Expected:**

- Claude stops without invoking `write-rule.sh` and explains that scope
  must be `user` or `project`.

## 9. Cleanup

After the manual run, remove the test rules added above:

```bash
jq '.allow = [] | .deny = []' ~/.claude/passthru.json > ~/.claude/passthru.json.tmp \
  && mv ~/.claude/passthru.json.tmp ~/.claude/passthru.json
rm -f .claude/passthru.json
```
