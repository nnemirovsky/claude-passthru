# CLAUDE.md

Developer-facing notes for future Claude sessions working on this repo.

## File structure

```
.claude-plugin/
  plugin.json          plugin manifest (name, version, description)
  marketplace.json     marketplace manifest (used when published)
commands/
  bootstrap.md         /passthru:bootstrap slash command (wraps scripts/bootstrap.sh with dry-run + confirm)
  add.md               /passthru:add slash command (prompt-based)
  suggest.md           /passthru:suggest slash command (prompt-based)
  list.md              /passthru:list slash command (wraps scripts/list.sh)
  remove.md            /passthru:remove slash command (wraps scripts/remove-rule.sh)
  verify.md            /passthru:verify slash command (prompt-based)
  log.md               /passthru:log slash command (prompt-based)
hooks/
  hooks.json           registers PreToolUse + PostToolUse + PostToolUseFailure
                       (timeout 10s each, matcher "*") and SessionStart
                       (timeout 5s, no matcher) handlers
  common.sh            shared library. Functions:
                         * load_rules / validate_rules (merge + schema-check)
                         * pcre_match / match_rule / find_first_match (rule matching)
                         * passthru_user_home, passthru_tmpdir, passthru_iso_ts,
                           passthru_sha256, sanitize_tool_use_id (env + path helpers)
                         * audit_enabled, audit_log_path, emit_passthrough
                           (audit + output helpers)
                         * write_post_event, is_denied_response,
                           is_permission_error_string, entries_look_tailored,
                           entry_matches_call, read_settings_allow,
                           read_settings_deny, classify_passthrough_outcome
                           (post-hook classification, shared by both post handlers)
                       Sourced by hook handlers AND by scripts/log.sh,
                       scripts/verify.sh, scripts/write-rule.sh.
  handlers/
    pre-tool-use.sh    main hook: loads rules, matches, emits allow/deny/passthrough
    post-tool-use.sh   classifies successful native-dialog outcomes into asked_* events.
                       Delegates to classify_passthrough_outcome in common.sh.
    post-tool-use-failure.sh
                       classifies failed tool calls. Permission-denied error strings ->
                       asked_denied_* via the same shared helper. Other failures ->
                       `errored` event (carries error_type, synthesizes timeout/interrupted
                       from is_timeout/is_interrupt when CC omits error_type).
    session-start.sh   bootstrap hint. Re-fires every session while importable entries in
                       settings.json / settings.local.json are not yet covered by
                       _source_hash values in passthru.imported.json. Hash diff replaces
                       the old one-shot marker. Auto-silences when migration is complete.
scripts/
  bootstrap.sh         one-time importer from native permissions.allow into passthru.imported.json.
                       Supported shapes: Bash(prefix:*) | Bash(exact) | mcp__* | WebFetch(domain:X)
                       | WebSearch | Read/Edit/Write(path[/**]) | Skill(name). Others -> [WARN] skip.
  write-rule.sh        atomic write wrapper: backup + append + verify + rollback
  remove-rule.sh       atomic remove wrapper: backup + splice + verify + rollback. Authored-only.
  list.sh              rule list viewer CLI with scope/list/source/index annotations
  verify.sh            rule verifier CLI (also invoked by write-rule.sh/remove-rule.sh and /passthru:verify)
  log.sh               audit-log viewer CLI + sentinel toggle
tests/
  fixtures/            JSON fixture files used by bats tests
  *.bats               test suites (one per script or component)
docs/
  rule-format.md       schema reference
  examples.md          real-world rule examples
  plans/               implementation plans (historical, not runtime)
README.md              user-facing documentation
CONTRIBUTING.md        contributor guide
CLAUDE.md              this file
```

Paths honor `PASSTHRU_USER_HOME` and `PASSTHRU_PROJECT_DIR` so tests never touch the real `~/.claude`.

## How tests run

All shell logic is covered by bats-core. Run the full suite:

```
bats tests/*.bats
```

Targeted run:

```
bats tests/hook_handler.bats
bats tests/verifier.bats
```

Conventions:

* Test files are named after the unit under test (`hook_handler.bats` covers `pre-tool-use.sh`, `verifier.bats` covers `scripts/verify.sh`, etc.).
* Every test creates a temp dir, sets `PASSTHRU_USER_HOME` and `PASSTHRU_PROJECT_DIR` to live under it, drops fixtures, and cleans up in `teardown`.
* No external network, no real home directory, no shared state between tests.

## How to pipe-test the hook

The hook reads JSON on stdin, writes a decision to stdout, and always exits 0 (fail-open).

```
echo '{
  "tool_name": "Bash",
  "tool_input": { "command": "gh api /repos/foo/bar/forks" }
}' | bash hooks/handlers/pre-tool-use.sh
```

With a custom rule location:

```
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | PASSTHRU_USER_HOME=/tmp/fakeuser PASSTHRU_PROJECT_DIR=/tmp/fakeproj \
    bash hooks/handlers/pre-tool-use.sh
```

Expected outputs:

* Allow match: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"..."}}`
* Deny match: same shape with `"deny"`.
* No match: `{"continue":true}`.

## Verifier CLI flags

`scripts/verify.sh` runs standalone and is also invoked by `write-rule.sh` after every machine-driven rule write.

```
bash scripts/verify.sh [flags]
```

Flags:

* `--scope user|project|all` - default `all`. Which scope's files to check.
* `--strict` - warnings (duplicates, shadowing) become a non-zero exit (exit 2 instead of 0).
* `--quiet` - suppress stdout on success. Errors still go to stderr.
* `--format plain|json` - default `plain`. JSON is machine-readable.
* `-h`, `--help` - usage.

Exit codes:

* `0` - clean, or warnings only without `--strict`.
* `1` - any error (bad JSON, schema violation, invalid regex, allow+deny conflict).
* `2` - warnings only and `--strict` is set.

Checks performed (in order, across the merged set):

1. **parse** - every existing file is valid JSON.
2. **schema** - every rule has at least one of `tool` or `match`, types match spec, version is `1`.
3. **regex** - every `tool` regex and every `match.*` regex compiles in perl.
4. **duplicates** - exact-duplicate rules (same tool + match) across scopes emit a warning.
5. **conflict** - identical `tool + match` appears in both `allow[]` and `deny[]` (merged) emits an error.
6. **shadowing** - within one merged `allow[]` or `deny[]` array, a later rule duplicates an earlier one. Warning.

## Write-wrapper locking

`scripts/write-rule.sh` (also called by `bootstrap.sh --write` and the
`/passthru:add`, `/passthru:suggest` commands) and `scripts/remove-rule.sh`
(called by `/passthru:remove`) serialize concurrent mutations via a single
user-scope lock directory at `~/.claude/passthru.write.lock.d`. The lock
uses `mkdir`, which is atomic on every POSIX filesystem we target (local
Linux/macOS plus NFS), works without any extra dependency, and polls at
100 ms intervals while waiting.

The lock-acquisition timeout is 5 seconds by default and is configurable via
`PASSTHRU_WRITE_LOCK_TIMEOUT=<seconds>` in the environment. Both
`tests/write_rule.bats` (concurrent test, lock-timeout test) and the
production write paths exercise the env override.

The lock directory lives under the **user** scope even for project-scope
writes because it is the single per-user serialization point across
concurrent project shells.

## Hook timeout

Both `PreToolUse` and `PostToolUse` are registered with `"timeout": 10` in
`hooks/hooks.json`. The reason for 10 seconds (rather than 2-3):

* `load_rules` shells out to `jq` once per rule file (up to 4 files), once for
  the parse check, once for normalization, and once for the merge.
* `find_first_match` runs `match_rule` per rule, which itself forks a `perl`
  PCRE check per regex.
* `audit_write_breadcrumb` snapshots two `sha256` digests of `settings.json`
  files plus a `jq` invocation to build the JSON envelope.
* On cold caches, slow disks, or under heavy IO load, a hot path with 50+
  rules + audit enabled has measured 2-4 seconds in the wild.
* The handler always exits 0 (fail-open) so a timeout would only ever lose
  audit fidelity, never block a tool call. Choosing 10s leaves 5x headroom
  over typical worst case.

Lower the timeout only after profiling on the target hardware. Higher is
fine.

## Releases

Use the `release-tools:new` skill (`/release-tools:new`) to cut a new release. The skill handles version calculation, the GitHub release, and the description prompt.

**Naming:**

* Tag: `vX.Y.Z` (e.g. `v0.2.0`).
* Release title: same as tag (`v0.2.0`), NOT `Version 0.2.0`.

**Version selection:**

* **Minor** (`v0.1.0` -> `v0.2.0`): default for most releases. Use when a PR adds `feat` commits, new commands, new rule-schema fields, or user-visible behavior changes.
* **Hotfix** (`v0.2.0` -> `v0.2.1`): PR contains `fix` commits exclusively (no feat, no breaking changes).
* **Major** (`v0.2.0` -> `v1.0.0`): breaking changes to rule schema (new `version`), slash command names, or hook contract. Always discuss with the user before a major bump. Never pick major autonomously.

**Skip releases for:** `chore`, `docs`, `ci`, `test` only PRs. The changes ship with the next feature release.

**Two-file version bump.** Before tagging, update BOTH of:

* `.claude-plugin/plugin.json` - the `version` field.
* `.claude-plugin/marketplace.json` - the `version` field at the top level.

Both take the numeric form without the `v` prefix (`0.2.0`, not `v0.2.0`). Commit the bump as:

```
chore(release): vX.Y.Z
```

Then create the tag `vX.Y.Z` (with the `v`). The `release-tools:new` skill may or may not handle the two-file bump automatically. If it does not, do the edits manually before invoking the skill, or update the skill invocation to cover both files.

The release flow in one-line form:

1. Merge the PR(s) into `main`.
2. Bump `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` to the new version.
3. Commit `chore(release): vX.Y.Z`.
4. Run `/release-tools:new` and pick the right increment.
5. Verify the tag and release appear on GitHub.

## Pointers for common tasks

* Adding a new slash command: create `commands/<name>.md` with the YAML frontmatter (see existing commands for the pattern). The file name becomes `/passthru:<name>` automatically.
* Adding a new hook event: register it in `hooks/hooks.json` and add a handler under `hooks/handlers/`. Reuse `hooks/common.sh` helpers where possible.
* Adding a new verifier check: see `CONTRIBUTING.md` section "Adding a new verifier check".
* Adding a new rule type or schema field: see `CONTRIBUTING.md` section "Rule schema evolution".
