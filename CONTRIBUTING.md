# Contributing

Thanks for looking at `claude-passthru`. This doc covers the dev loop, how tests run, and the rule-schema evolution policy.

## Local dev loop

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/claude-passthru
```

Every Claude Code restart re-reads the plugin from disk. No `/plugin install`, no marketplace cache to flush. This is the fastest iteration loop.

The scripts and hooks honor two environment overrides so bats tests and local experiments do not touch your real `~/.claude`:

* `PASSTHRU_USER_HOME` - overrides the user scope root. Default `$HOME`.
* `PASSTHRU_PROJECT_DIR` - overrides the project scope root. Default `$PWD`.

## Running tests

All shell logic is covered by bats. Run the full suite:

```
bats tests/*.bats
```

Targeted run for one file while iterating:

```
bats tests/hook_handler.bats
```

Install bats-core 1.9+ from Homebrew (`brew install bats-core`) or npm (`npm install -g bats`).

The test fixtures live under `tests/fixtures/` and cover every combination of user-scope, project-scope, authored, and imported rule files.

## Pipe-testing the hook manually

The `PreToolUse` hook reads JSON on stdin and writes a decision to stdout. You can exercise it without Claude Code attached:

```
echo '{
  "tool_name": "Bash",
  "tool_input": { "command": "gh api /repos/foo/bar/forks" }
}' | bash hooks/handlers/pre-tool-use.sh
```

Expected output: the hook's decision JSON (`{ "hookSpecificOutput": { "permissionDecision": "allow", ... } }` when a rule matches, `{ "continue": true }` on passthrough).

Point the hook at a specific rule set via env overrides:

```
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | PASSTHRU_USER_HOME=/tmp/fakeuser PASSTHRU_PROJECT_DIR=/tmp/fakeproj \
    bash hooks/handlers/pre-tool-use.sh
```

The `PostToolUse` handler works the same way (it reads the `tool_use_id` and classifies the native dialog outcome).

## Rule schema evolution

`passthru.json` files have a top-level `version` field. Today only `version: 1` is recognized and the verifier rejects anything else.

When adding a breaking change to the schema (renaming a field, changing a field's semantics, removing a field):

1. Bump the schema version from `1` to `2` in the verifier, hook, and docs.
2. Add a migration path if the new format cannot be read by the old loader. At minimum, the verifier should print a clear error pointing users at an upgrade doc.
3. Call the change out in the release notes (see Releases section in `CLAUDE.md`).

Non-breaking additions (new optional fields, new optional top-level keys) do not require a version bump. They stay on `version: 1`.

## Adding a new verifier check

`scripts/verify.sh` has a stable structure. Add a new check by following the existing pattern:

1. Inside the per-file schema pass, add a branch that tests the condition and calls the `diag` helper:
   ```
   diag error "$file" ".allow[$idx].some_field" "$idx" "schema: some_field must be ..."
   ```
   Use `diag warn` for non-fatal findings. The helper takes care of JSON vs plain output formatting and increments the right counter.
2. Cross-file checks (duplicates, conflicts, shadowing) live later in the script and operate on the merged rule set. Add new cross-file checks there.
3. Add bats tests in `tests/verifier.bats` covering the success and failure case. Fixtures go in `tests/fixtures/`.

## Branch policy

`main` is protected on GitHub. All changes must go through pull requests. Direct pushes to `main` are blocked.

Commits follow the scoped Conventional Commits style: `type(scope): description`. Scope is always required. PR titles use the same format.

Release cuts happen from `main` via the `release-tools:new` skill. Never cut a release from a feature branch. See the `Releases` section in `CLAUDE.md` for the full procedure.
