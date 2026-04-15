---
description: Remove an authored passthru rule by scope, list, and 1-based index
argument-hint: "<scope> <list> <index>"
---

# /passthru:remove

Remove a single authored passthru rule by scope, list, and 1-based
index. Imported rules (written by `scripts/bootstrap.sh`) are not
removable here because bootstrap regenerates them on every run. To
drop an imported rule, remove the corresponding `permissions.allow`
entry from your `settings.json` and re-run bootstrap.

Run `/passthru:list` first to see the indexes.

## What you must do

You are Claude. Parse `$ARGUMENTS` and shell out to the remove script.
Do not invent behaviour. Surface errors verbatim.

### 1. Tokenize `$ARGUMENTS`

Three positional tokens are required, in this order:

1. `scope` - must be `user` or `project`.
2. `list` - must be `allow` or `deny`.
3. `index` - positive integer, 1-based, from the `#` column of
   `/passthru:list` under the matching `(scope, list, authored-source)`
   group.

If any are missing or malformed, tell the user:
`usage: /passthru:remove <scope> <list> <index>` and stop.

### 2. Invoke the remove wrapper

Run exactly:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/remove-rule.sh <scope> <list> <index>
```

Capture stdout, stderr, and the exit code.

### 3. Handle the result

**Exit 0:** the script prints
`removed <scope>/<list>/<index>: <tool-summary>` on stdout. Echo that
back to the user plus a reminder that the file is now one rule
shorter. Optionally offer to run `/passthru:list` to confirm.

**Exit 1:** invalid args, rule not found, or the user tried to remove
an imported rule. Surface stderr verbatim. If the message mentions
`cannot remove imported rule`, explain that bootstrap-managed rules
are regenerated from `settings.json` and suggest editing that file
followed by `/passthru:bootstrap --write`.

**Exit 2:** the verifier rejected the post-remove state. The remove
script has already restored the backup. Show the verifier's stderr
verbatim and suggest `/passthru:verify` for a full report. This is
rare in practice since removing a rule cannot introduce a new
violation.

### 4. Guidance

* Recommend `/passthru:list` before `/passthru:remove` so the user
  sees live indexes. Indexes shift down after a remove, so consecutive
  removes should re-check the list.
* Remember that `remove` only operates on authored files
  (`passthru.json`), never on imported ones.

## Examples

* Remove the 3rd authored allow rule from the user scope:

  ```
  /passthru:remove user allow 3
  ```

* Remove the first authored deny rule from the project scope:

  ```
  /passthru:remove project deny 1
  ```

* Typical workflow:

  ```
  /passthru:list
  /passthru:remove user allow 2
  /passthru:list        # confirm the remaining rules
  ```
