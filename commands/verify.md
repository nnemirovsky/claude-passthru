---
description: Verify passthru rule files for correctness
argument-hint: "[--scope user|project|all] [--strict]"
---

# /passthru:verify

Validate every known `passthru.json` file (user-authored, user-imported,
project-authored, project-imported) in one pass. Use this after editing
`passthru.json` directly or whenever you suspect a rule file is malformed.

The plugin's `PreToolUse` hook silently skips invalid rule files at runtime,
so a typo can quietly disable your allow/deny rules. Running this command
surfaces the failure before the next tool call.

## What you must do

You are Claude. Run the verifier script with `$ARGUMENTS` passed through,
then present the result clearly. Do not paraphrase script output - quote
errors verbatim and explain what the user should do.

### 1. Run the verifier

Invoke exactly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh $ARGUMENTS
```

Capture stdout, stderr, and the exit code. The script accepts:

- `--scope user|project|all` - default `all`.
- `--strict` - warnings (duplicates, shadowing) become a non-zero exit.
- `--quiet`, `--format plain|json` - also passable; rarely needed here.

### 2. Present the result

Branch on the exit code:

**Exit 0 (clean):** the script prints `[OK] N rules across M files checked`
(or `[OK] no rules ...` when nothing exists yet). Confirm to the user that
all rule files parsed and every regex compiled, and stop there. No further
action needed.

**Exit 1 (errors):** the script prints `[ERR] <file>:<jq-path> [rule N] <msg>`
lines on stderr. Show every error verbatim, then explain each one in plain
language and suggest the fix:

- `parse: ...` - the file is not valid JSON. Open it and fix the syntax
  error (often a trailing comma, unterminated string, or stray character).
- `schema: rule must have at least one of "tool" or "match"` - the rule
  object is empty or only carries `reason`. Add a `tool` regex or a
  `match` block.
- `schema: .tool must be string` / `.match must be object` - the field has
  the wrong type. Fix the JSON shape.
- `schema: match value must be non-empty` - the inner regex is `""`. Fill
  it in or remove the field.
- `schema: unsupported version N` - only `version: 1` is recognized today.
  Set the file's `version` to `1`.
- `regex: invalid pattern '<pat>': <perl error>` - the regex does not
  compile. Common causes: unbalanced parens, dangling `\`, unmatched
  bracket, or a stray `*`/`+` at the start. Edit the pattern and re-run.
- `conflict: same tool+match appears in both allow and deny` - the same
  rule identity exists in both lists across the merged scope set. Remove
  the rule from one side. The hook would treat conflicts as ambiguous.

After listing the errors and explanations, suggest the user fix the file
in their editor and re-run `/passthru:verify` to confirm.

**Exit 2 (warnings, only with `--strict`):** the script prints `[WARN] ...`
lines for duplicates and shadowing. Show them and explain:

- `duplicate: same rule identity appears in multiple places` - the same
  `tool + match` pair exists in more than one file or list. Harmless but
  noisy. Remove the redundant copy.
- `shadowing: rule N shadowed by earlier identical rule at index M` -
  inside the merged allow[] (or deny[]) array, a later rule duplicates an
  earlier one. The later rule never fires. Remove it.

These do not cause an exit-1 failure without `--strict`. Suggest the user
either accept the warnings or clean them up.

### 3. Guidance

End the response with a short reminder: when the user edits
`passthru.json` directly (instead of going through `/passthru:add` or
`/passthru:suggest`), they should run `/passthru:verify` after editing
`passthru.json` directly to catch errors before your next tool call.

## Examples

- Verify both scopes (default):

  ```
  /passthru:verify
  ```

- Verify only the user scope, strict mode:

  ```
  /passthru:verify --scope user --strict
  ```

- Verify only the current project:

  ```
  /passthru:verify --scope project
  ```
