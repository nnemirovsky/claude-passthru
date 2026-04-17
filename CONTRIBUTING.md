# Contributing

Thanks for looking at `claude-passthru`. This doc covers the dev loop, how tests run, and the rule-schema evolution policy.

## Local dev loop

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/claude-passthru
```

Every Claude Code restart re-reads the plugin from disk. No `/plugin install`, no marketplace cache to flush. This is the fastest iteration loop.

The scripts and hooks honor environment overrides so bats tests and local experiments do not touch your real `~/.claude`:

* `PASSTHRU_USER_HOME` - overrides the user scope root. Default `$HOME`.
* `PASSTHRU_PROJECT_DIR` - overrides the project scope root. Default `$PWD`.
* `PASSTHRU_WRITE_LOCK_TIMEOUT` - lock acquisition timeout in seconds for `scripts/write-rule.sh` (and the slash commands plus `bootstrap.sh --write` that call into it). Default `5`. Lower it in concurrency tests, raise it on slow filesystems.

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

## Extending the readonly command list

The readonly auto-allow list lives in `hooks/common.sh` across three arrays:

* `PASSTHRU_READONLY_COMMANDS` - simple commands using the generic safety regex (`^<cmd>(?:\s|$)[^<>()$\x60|{}&;\n\r]*$`). Add commands here when the generic regex is sufficient (no special flags or subcommands to worry about).
* `PASSTHRU_READONLY_TWO_WORD_COMMANDS` - two-word commands like `docker ps` that use the same generic safety regex with the full two-word prefix.
* `PASSTHRU_READONLY_CUSTOM_REGEXES` - full PCRE patterns for commands needing custom validation (e.g. `echo` rejects `$`/backticks, `find` rejects `-exec`/`-delete`, `jq` rejects `-f`/`--from-file`).

To add a new readonly command:

1. Decide which array it belongs in. Most simple commands go in `PASSTHRU_READONLY_COMMANDS`. Only use a custom regex when the generic safety pattern is insufficient.
2. Add the entry to the appropriate array in `hooks/common.sh`.
3. Add tests in `tests/hook_handler.bats` covering both the positive case (command auto-allowed) and the negative case (dangerous variant not auto-allowed).
4. Run the full test suite: `bats tests/*.bats`.

The list mirrors Claude Code's `readOnlyValidation.ts`. Check CC source when adding commands to keep the two lists in sync.

## Extending the compound command splitter

The compound command splitter (`split_bash_command` in `hooks/common.sh`) uses inline perl to tokenize Bash commands. It handles:

* Single/double quotes, `$()` subshells (nested), backticks, backslash escaping
* Splitting on unquoted `|`, `&&`, `||`, `;`, `&`
* Stripping redirections (`>`, `>>`, `<`, `2>&1`, `N>file`)

The per-segment matching algorithm (`match_all_segments` in `hooks/common.sh`) implements:

* Deny: ANY segment matching a deny rule blocks the whole command
* Allow: ALL segments must match. Different segments may match different rules
* Ask: ANY segment matching ask (with no deny) triggers ask

Tests live in `tests/command_splitting.bats` (splitter unit tests) and `tests/hook_handler.bats` (integration tests for compound matching in the hook).

When modifying the splitter:

1. Add tests in `tests/command_splitting.bats` first.
2. The fail-safe behavior (parse errors return original command as one segment) must be preserved.
3. The perl tokenizer handles all splitting and redirection stripping in a single process for performance.

## Working with `allowed_dirs`

The `allowed_dirs` field in passthru.json extends the set of trusted directories for path-based auto-allow. When adding or modifying `allowed_dirs` support:

* `load_allowed_dirs` in `hooks/common.sh` reads all four rule files and returns a deduplicated JSON array. It is separate from `load_rules` to preserve the `{version, allow, deny, ask}` contract.
* `_pm_path_inside_any_allowed` checks a path against both cwd and each allowed dir. It is used by `permission_mode_auto_allows` and `readonly_paths_allowed`.
* `permission_mode_auto_allows` accepts an optional 5th parameter (`allowed_dirs_json`). Callers that do not pass it get the old behavior (cwd only).
* `validate_rules` tolerates the `allowed_dirs` key and validates entries: must be an array of non-empty strings, rejects path traversal (`/../`).
* Bootstrap imports `additionalAllowedWorkingDirs` from CC's `settings.json` via `extract_allowed_dirs` and writes them to `allowed_dirs` in `passthru.imported.json`.

## Branch policy

`main` is protected on GitHub. All changes must go through pull requests. Direct pushes to `main` are blocked.

Commits follow the scoped Conventional Commits style: `type(scope): description`. Scope is always required. PR titles use the same format.

Release cuts happen from `main` via the `release-tools:new` skill. Never cut a release from a feature branch. See the `Releases` section in `CLAUDE.md` for the full procedure.
