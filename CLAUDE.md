# CLAUDE.md

Developer-facing notes for future Claude sessions working on this repo.

## File structure

```
.claude-plugin/
  plugin.json          plugin manifest (name, version, description)
  marketplace.json     marketplace manifest (used when published)
commands/
  add.md               /passthru:add slash command (prompt-based)
  suggest.md           /passthru:suggest slash command (prompt-based)
  verify.md            /passthru:verify slash command (prompt-based)
  log.md               /passthru:log slash command (prompt-based)
hooks/
  hooks.json           registers PreToolUse + PostToolUse handlers with matcher "*"
  common.sh            shared library: rule loading, merging, schema validation, PCRE matching
  handlers/
    pre-tool-use.sh    main hook: loads rules, matches, emits allow/deny/passthrough
    post-tool-use.sh   classifies native-dialog outcomes into asked_* events (audit only)
scripts/
  bootstrap.sh         one-time importer from native permissions.allow into passthru.imported.json
  write-rule.sh        atomic write wrapper: backup + append + verify + rollback
  verify.sh            rule verifier CLI (also invoked by write-rule.sh and /passthru:verify)
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
`/passthru:add`, `/passthru:suggest` commands) serializes concurrent writers
via a single user-scope lock at `~/.claude/passthru.write.lock`. Two backends
exist:

* **flock** when the binary is on `$PATH` (Linux distros, macOS via Homebrew).
  Uses `flock -w "$LOCK_TIMEOUT" 9` against the lockfile.
* **mkdir fallback** otherwise (default macOS install). Uses
  `~/.claude/passthru.write.lock.d` as an atomic directory marker, polling at
  100 ms intervals.

The lock-acquisition timeout is 5 seconds by default and is configurable via
`PASSTHRU_WRITE_LOCK_TIMEOUT=<seconds>` in the environment. Both
`tests/write_rule.bats` (concurrent test, lock-timeout test) and the
production write paths exercise the env override.

The lock file lives under the **user** scope even for project-scope writes
because it is the single per-user serialization point across concurrent
project shells.

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
