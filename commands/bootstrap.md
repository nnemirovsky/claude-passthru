---
description: "Import existing native permission rules into passthru"
argument-hint: "[--user-only|--project-only]"
---

# /passthru:bootstrap

Convert existing native Claude Code `permissions.allow` entries (from
`~/.claude/settings.json` and `./.claude/settings{,.local}.json`) into
passthru rule files, with an interactive preview before anything is
written.

This is the in-session wrapper around `scripts/bootstrap.sh`. The shell
script is always available for non-interactive use, but this command is
the recommended first-run path: it shows exactly what will be imported,
asks for confirmation, and then verifies the result.

Hand-authored `passthru.json` files are never touched. Imports always
land in `passthru.imported.json` (separately per scope). Re-running this
command overwrites the imported files in place.

## What you must do

You are Claude. Drive the workflow below. Surface errors verbatim. Do
not skip the confirmation step.

### 1. Dry-run to collect the proposed rules

Invoke the bootstrap script WITHOUT `--write`, passing `$ARGUMENTS`
through so the user's `--user-only` / `--project-only` choice is
honored:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap.sh $ARGUMENTS
```

Capture stdout, stderr, and the exit code. The script emits:

- `# would write: <path>` comment lines (one per scope in play).
- A pretty-printed JSON document per scope, of shape
  `{"version":1,"allow":[...],"deny":[]}`.
- `[WARN] skipping ...` lines on stderr for unsupported native rule
  forms (spaces past the prefix, unusual `WebFetch(...)` forms, etc.).
  These are informational, not fatal.

Non-zero exit means the script itself failed (malformed
`settings.json`, for example). In that case, surface the error
verbatim and stop.

### 2. Count the proposed rules

Parse the dry-run output. For each `# would write:` block, count
`.allow | length` in the JSON document that follows it. Record the
count per scope (`user` and/or `project`) and the grand total.

### 3. Handle the nothing-to-import case

If the grand total is zero (no scopes have any rules, or `$ARGUMENTS`
limited the run to a scope with no importable rules), tell the user:

> Nothing to import. Your `settings.json` has no convertible
> `permissions.allow` entries in the selected scope.

Then suggest one of these next steps, pick whichever fits the
situation:

- `/passthru:add <scope> <tool> <pattern> <reason>` to author a rule
  by hand.
- `/passthru:suggest <hint>` to generalize a rule from a recent tool
  call in the conversation.

Stop there. Do not invoke `--write`.

### 4. Show the proposal

Otherwise, present the proposal in this order:

1. A one-line summary: `Found N importable rule(s): user=<u>,
   project=<p>.` (omit the zero-count scope).
2. For each scope with rules, show the proposed rules. A compact
   format is fine - list each rule's `tool` field plus a summary of
   the `match` block (or `(namespace rule, no match)` for MCP
   namespace rules). Quote the reason if present.
3. Explain where they land:
   > This will import N rule(s) from your existing `settings.json`
   > files. Your hand-authored `passthru.json` is never touched;
   > imports go to `passthru.imported.json` (separately per scope).
   > Re-running this command overwrites the imported files in place.
4. If the dry-run emitted any `[WARN]` lines on stderr, show them
   and explain that those native entries were skipped because the
   converter does not have a safe regex translation for their shape.
   The user can still add them via `/passthru:add` or
   `/passthru:suggest`.

### 5. Ask for confirmation

Ask the user plainly: "Write these rules now? (yes / no)". Wait for a
clear answer.

- `yes` / `y` / `write` -> proceed to step 6.
- `no` / `n` / `cancel` -> tell the user nothing was written and
  stop. Remind them they can re-run `/passthru:bootstrap` when they
  are ready, or use `/passthru:add` / `/passthru:suggest` instead.
- Ambiguous answer -> re-ask once. If still ambiguous, treat as no.

The scope choice is already fixed by whatever the user passed in
`$ARGUMENTS` (default = both scopes). Do not ask about scope here.

### 6. Write the rules

On confirmation, invoke the script again with `--write` and the same
`$ARGUMENTS`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap.sh --write $ARGUMENTS
```

The script backs up any existing `passthru.imported.json`, writes the
new document, then runs `scripts/verify.sh --quiet`. If the verifier
fails, the script restores the backup and exits non-zero. Surface
non-zero output verbatim and stop.

On success the script prints `wrote <path>` per scope.

### 7. Run the verifier once more

Independently re-run the verifier to confirm the imported files parse
cleanly alongside any existing hand-authored rules:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh
```

If this exits non-zero, show the errors verbatim. The bootstrap
script has already rolled back on its own verify failure, so an exit
here means something else (e.g. a pre-existing problem in
`passthru.json` that the merged view now surfaces).

### 8. Report success

Print a short confirmation:

> Imported N rule(s). Restart Claude Code to pick the new rules up,
> or wait - the PreToolUse hook re-reads every rule file on every
> tool call, so the imports take effect on the very next tool call in
> this session.

If the dry-run emitted `[WARN]` lines for skipped entries, remind the
user once more that they can port those manually via `/passthru:add`
or `/passthru:suggest`.

## Examples

### Both scopes, importable rules in user scope only

Dry-run output:

```
# would write: /Users/you/.claude/passthru.imported.json
{
  "version": 1,
  "allow": [
    { "tool": "Bash", "match": { "command": "^ls(\\s|$)" }, "reason": "imported from settings" },
    { "tool": "Bash", "match": { "command": "^gh api(\\s|$)" }, "reason": "imported from settings" }
  ],
  "deny": []
}
# would write: /Users/you/project/.claude/passthru.imported.json
{ "version": 1, "allow": [], "deny": [] }
```

Present:

> Found 2 importable rule(s): user=2.
> 
> user scope:
> - `Bash` match `command: ^ls(\s|$)` - imported from settings
> - `Bash` match `command: ^gh api(\s|$)` - imported from settings
> 
> This will import 2 rules from your existing settings.json files.
> Your hand-authored passthru.json is never touched; imports land in
> passthru.imported.json.
> 
> Write these rules now? (yes / no)

After confirmation and `--write`:

> Imported 2 rule(s). Restart Claude Code (or wait - rules take
> effect on the next tool call since the hook re-reads every
> invocation).

### `--user-only`

```
/passthru:bootstrap --user-only
```

Skips the project scope entirely. Only writes
`~/.claude/passthru.imported.json`. Useful when project-scope
`settings.local.json` has a lot of one-off rules you do not want
ported plugin-side.

### Nothing to import

```
/passthru:bootstrap
```

Dry-run emits two empty documents. Respond:

> Nothing to import. Your settings.json has no convertible
> permissions.allow entries in the selected scope.
> 
> Next steps:
> - `/passthru:add user Bash "^gh api " "github api reads"` to add a
>   rule by hand.
> - `/passthru:suggest gh api` to generalize a rule from a recent
>   tool call.

Do not invoke `--write`.
