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
  overlay.md           /passthru:overlay slash command (wraps scripts/overlay-config.sh)
hooks/
  hooks.json           registers PreToolUse (timeout 300s, matcher "*"), PostToolUse +
                       PostToolUseFailure (timeout 10s each, matcher "*"), and
                       SessionStart (timeout 5s, no matcher) handlers
  common.sh            shared library. Functions:
                         * load_rules / validate_rules (merge + schema-check)
                         * load_allowed_dirs (read + deduplicate allowed_dirs from all rule files)
                         * pcre_match / match_rule / find_first_match (rule matching)
                         * split_bash_command (compound command splitter via perl tokenizer)
                         * match_all_segments (per-segment matching for compound Bash commands)
                         * is_readonly_command / readonly_paths_allowed (readonly auto-allow)
                         * _pm_path_inside_any_allowed (path validation against cwd + allowed dirs)
                         * build_ordered_allow_ask (document-order allow/ask interleaving)
                         * permission_mode_auto_allows (CC mode replication with allowed dirs)
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
    pre-tool-use.sh    main hook: splits compound Bash commands, checks deny per segment,
                       readonly auto-allow, allow/ask document-order matching (per-segment
                       for compound commands), mode auto-allow with allowed dirs, overlay
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
                       Stamps every written rule with `_source_hash` (sha256 of the normalized
                       source entry) so session-start.sh can diff imported vs importable.
  write-rule.sh        atomic write wrapper: backup + append + verify + rollback. Also the
                       v1 -> v2 upgrade point: first ask write on a v1 file flips the version.
  remove-rule.sh       atomic remove wrapper: backup + splice + verify + rollback. Authored-only.
  list.sh              rule list viewer CLI with scope/list/source/index annotations. Renders
                       ALLOW / ASK / DENY groups; --list ask filters.
  verify.sh            rule verifier CLI (also invoked by write-rule.sh/remove-rule.sh and /passthru:verify).
                       Accepts schema v1 and v2. Rejects ask+allow and ask+deny conflicts.
  log.sh               audit-log viewer CLI + sentinel toggle. color_for_event covers
                       ask (cyan), errored (yellow), and overlay-sourced events.
  overlay.sh           terminal-multiplexer dispatcher. Detects tmux / kitty / wezterm via
                       env vars + PATH check, launches overlay-dialog.sh inside the popup.
                       Writes verdict to $PASSTHRU_OVERLAY_RESULT_FILE.
  overlay-dialog.sh    pure-bash TUI. Y/A/N/D/Esc keypress menu, optional rule editor on A/D.
                       Respects PASSTHRU_OVERLAY_TEST_ANSWER for hermetic tests.
                       PASSTHRU_OVERLAY_TIMEOUT bounds the wait (default 60s).
  overlay-propose-rule.sh
                       regex proposer. Takes tool_name + tool_input JSON, emits a rule JSON
                       targeting one of four categories (Bash fully-anchored with safe char class,
                       Read/Edit/Write path prefix, WebFetch URL host, MCP namespace).
                       Unknown tool -> bare ^<Name>$ rule.
  overlay-config.sh    overlay sentinel toggle + multiplexer detection reporter. Backs
                       /passthru:overlay.
tests/
  fixtures/
    overlay/           stub tmux/kitty/wezterm shell scripts used by overlay tests.
    *.json             JSON fixture files.
  overlay.bats         overlay.sh + overlay-dialog.sh + overlay-propose-rule.sh coverage.
  overlay_config.bats  overlay-config.sh + /passthru:overlay frontmatter coverage.
  post_tool_use_failure_hook.bats
                       PostToolUseFailure handler coverage (permission errors, generic
                       errored events, timeouts, interrupts, missing breadcrumb).
  command_splitting.bats  split_bash_command + match_all_segments coverage (compound
                       command splitting, redirection stripping, quote/subshell handling).
  *.bats               test suites (one per script or component).
docs/
  rule-format.md       schema reference
  examples.md          real-world rule examples
  plans/               implementation plans (historical, not runtime)
README.md              user-facing documentation
CONTRIBUTING.md        contributor guide
CLAUDE.md              this file
```

Paths honor `PASSTHRU_USER_HOME` and `PASSTHRU_PROJECT_DIR` so tests never touch the real `~/.claude`.

## Environment variables

Variables the plugin reads at runtime. Most are test-only overrides; a couple (`PASSTHRU_OVERLAY_TIMEOUT`, `PASSTHRU_WRITE_LOCK_TIMEOUT`) have user-facing meaning.

* `PASSTHRU_USER_HOME` - override `~/.claude` as the user scope root. Used by every bats test to redirect reads and writes to a temp dir. Never set in production.
* `PASSTHRU_PROJECT_DIR` - override `$PWD/.claude` as the project scope root. Same use case as above. Tests set both.
* `PASSTHRU_OVERLAY_RESULT_FILE` - path the overlay dispatcher writes the verdict line(s) into. Set by `pre-tool-use.sh` per-invocation via `sanitize_tool_use_id` + `passthru_tmpdir`. The overlay script reads the path from this env var; the hook reads back the contents after the overlay exits.
* `PASSTHRU_OVERLAY_TEST_ANSWER` - short-circuit the interactive keypress loop in `overlay-dialog.sh`. Accepts `yes_once|yes_always|no_once|no_always|cancel`. Used exclusively by `tests/overlay.bats` + `tests/hook_handler.bats` to exercise every branch without pseudo-tty gymnastics. Never set by the hook in production.
* `PASSTHRU_OVERLAY_TOOL_NAME` - tool name passed into the overlay dialog. Hook propagates the inbound `tool_name` field verbatim.
* `PASSTHRU_OVERLAY_TOOL_INPUT_JSON` - tool input JSON (stringified) passed into the overlay dialog. Hook propagates the inbound `tool_input` field verbatim. The dialog and `overlay-propose-rule.sh` parse it for the suggested-rule screen.
* `PASSTHRU_OVERLAY_TIMEOUT` - seconds to wait for a user response inside the overlay. Default 60. If the user does not respond in time, the overlay exits without writing a verdict and the hook treats the prompt as cancelled (falls through to the native dialog). Setting below 60 is fine; setting above requires also raising the PreToolUse hook timeout (currently 300s).
* `PASSTHRU_OVERLAY_LOCK_TIMEOUT` - seconds to wait for another CC session's overlay to release the user-scope queue lock. Default 180. On timeout, the hook emits the ask fallback (native dialog). See the "Overlay queue lock" section below.
* `PASSTHRU_OVERLAY_LOCK_STALE_AFTER` - mtime age threshold in seconds after which an existing overlay lock is considered abandoned and auto-cleared. Default 180. Protects against SIGKILLed hooks leaving zombie locks.
* `PASSTHRU_OVERLAY_UNALLOWED_SEGMENTS` - newline-separated list of compound Bash segments that are NOT covered by readonly auto-allow or by any allow/ask rule. Set by `pre-tool-use.sh` before invoking the overlay. Read by `overlay-propose-rule.sh` so that "yes/no always" proposals target only the uncovered portion instead of the full command's first word.
* `PASSTHRU_WRITE_LOCK_TIMEOUT` - seconds `scripts/write-rule.sh` and `scripts/remove-rule.sh` wait for the user-scope mkdir lock. Default 5. See the "Write-wrapper locking" section below.

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
2. **schema** - every rule has at least one of `tool` or `match`, types match spec, version is `1` or `2`. v2 files may declare `ask[]`; rules in `ask[]` are validated with the same rule-shape checks as `allow[]` and `deny[]`.
3. **regex** - every `tool` regex and every `match.*` regex compiles in perl.
4. **duplicates** - exact-duplicate rules (same tool + match) across scopes emit a warning.
5. **conflict** - identical `tool + match` appears in two or more of `allow[]`, `deny[]`, `ask[]` (merged) emits an error.
6. **shadowing** - within one merged `allow[]`, `deny[]`, or `ask[]` array, a later rule duplicates an earlier one. Warning.

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

`PostToolUse`, `PostToolUseFailure`, and `SessionStart` are registered with
short timeouts (10s / 10s / 5s) in `hooks/hooks.json`. `PreToolUse` runs with
a **300s** timeout because the hook blocks synchronously on the interactive
terminal-overlay dialog AND may also queue behind an overlay held by another
CC session on the same machine.

The 300s figure breaks down as:

* The overlay dialog (`scripts/overlay-dialog.sh`) enforces its own 60s
  budget (`PASSTHRU_OVERLAY_TIMEOUT`, default 60s).
* The overlay queue lock (`PASSTHRU_OVERLAY_LOCK_TIMEOUT`, default 180s)
  waits for other sessions' overlays to complete.
* Add margin for overlay launch, multiplexer roundtrip, post-dialog
  rule write via `write-rule.sh`, and audit line emission.
* CC's hook timeout is wall-clock. Anything below the overlay's own budget
  plus the lock-wait budget would kill the hook mid-wait and lose the
  user's verdict.

The 10s baseline for non-overlay PreToolUse paths (rule match, mode
auto-allow) still applies in the sense that none of them block on IO; the
300s cap only matters when the overlay is actually invoked.

For post-event handlers, the original 10s baseline continues to hold:

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

Lower the PreToolUse timeout only after also lowering
`PASSTHRU_OVERLAY_TIMEOUT` (and only after profiling on target hardware).
Raising it is always safe since the handler fails open on timeout.

## Overlay queue lock (cross-session)

The overlay popup is singleton per machine: tmux/kitty/wezterm can only
show one popup at a time. Two CC sessions racing for the overlay would
otherwise both try to open popups and one would fail, falling through to
CC's native dialog.

`hooks/handlers/pre-tool-use.sh` serializes overlays via a mkdir lock at
`$(passthru_user_home)/passthru-overlay.lock.d`. The lock MUST live under
user home, NOT `$TMPDIR`: on macOS `$TMPDIR` resolves to a per-process
`/var/folders/<session-id>/.../T/` folder that is NOT shared across CC
sessions of the same user. User home is the only guaranteed shared
location.

Stale-lock recovery runs every ~2s during wait. If the existing lock's
mtime is older than `PASSTHRU_OVERLAY_LOCK_STALE_AFTER` (default 180s),
the lock is force-removed. This prevents a hook that was SIGKILLed
(OOM, manual kill) from blocking every subsequent overlay forever.

Env knobs:

* `PASSTHRU_OVERLAY_LOCK_TIMEOUT` (default 180s) - how long to wait for
  another session's overlay before falling back to CC's native dialog.
* `PASSTHRU_OVERLAY_LOCK_STALE_AFTER` (default 180s) - mtime age at which
  an existing lock is considered abandoned and auto-cleared.

## Interaction with CC's native permission system

Passthru is one of potentially several PreToolUse hooks AND sits alongside
CC's built-in permission evaluation. Understanding which decision wins in
which scenario is essential for debugging "why did the native dialog
appear?" complaints.

**Decision cascade after PreToolUse hooks return:**

1. If any hook emits `permissionDecision: "allow"` - CC proceeds silently.
2. If any hook emits `permissionDecision: "deny"` - CC blocks the tool.
3. If a hook emits `permissionDecision: "ask"` - CC shows its NATIVE
   dialog. This is by design: "ask" explicitly defers to CC's UI.
4. If all hooks pass through (`{"continue": true}`) - CC evaluates its own
   `permissions.allow` entries from `settings.json`. If none match, CC
   shows its native dialog.

Implication: passthru emitting `ask` (either explicitly or via overlay
fall-through / lock timeout) will trigger a native dialog. Only `allow`
fully suppresses it. This is why the compound readonly-filter fix (`go
test | tail` now resolves to allow instead of ask) eliminates the native
dialog cascade.

**Multi-plugin hook ordering:**

CC runs PreToolUse hooks in plugin registration order. Each subsequent
hook sees `tool_input` as MODIFIED by previous hooks. Plugins like `rtk`
(which rewrites `go test` to `rtk go test`) can either run before or
after passthru depending on ordering:

* rtk BEFORE passthru: passthru sees `rtk go test ...`. User rule for
  `^go` does not match. Falls through to overlay.
* rtk AFTER passthru: passthru sees `go test ...`. User rule matches,
  decision is "allow". CC then runs rtk which rewrites the command, CC
  executes the rewritten command.

If the user reports seeing the overlay for BOTH `go ...` and `rtk go ...`
variants intermittently, hook ordering is non-deterministic or multiple
rtk code paths (proxy vs rewrite) are in play. Rule coverage should
anticipate both forms or use a broader pattern.

## Notifications on overlay prompt

`pre-tool-use.sh` sends an OSC 777 desktop notification before invoking
the overlay so the user knows a prompt is waiting. Two gotchas:

* Must write to `/dev/tty`, NOT stdout. Stdout is captured by CC as the
  hook's JSON response and the OSC sequence would pollute (or invalidate)
  the JSON payload.
* Inside tmux, the OSC must be wrapped in DCS passthrough: `ESC P tmux;
  <inner> ESC \` with every inner `ESC` doubled. Additionally tmux needs
  `set -g allow-passthrough on` in the user's tmux.conf. Without
  passthrough, tmux strips the OSC and Ghostty/iTerm2 never sees it.

OSC 777 format: `ESC ] 777 ; notify ; <title> ; <body> BEL`. Supported
by Ghostty, iTerm2, Konsole, and most modern terminal emulators.

## Compound command splitting

For Bash tool calls, the hook splits compound commands into segments before
matching. The splitter (`split_bash_command` in `hooks/common.sh`) uses
inline perl to tokenize the command respecting single quotes, double quotes,
`$()` subshells, backticks, and backslash escaping. It splits on unquoted
`|`, `&&`, `||`, `;`, and `&`, and strips redirections (`>`, `>>`, `<`,
`2>&1`, `N>file`) from each segment.

Matching after splitting follows these rules:

* **Deny**: each segment is checked against deny rules. ANY segment matching
  a deny rule causes the whole command to be denied.
* **Allow**: ALL segments must match allow rules (each segment may match a
  different rule). If any segment has no match, the command falls through.
* **Ask**: if any segment's first match is an ask rule (and no segment was
  denied), the whole command triggers ask.

Fail-safe: parse errors (unterminated quotes, etc.) return the original
command as a single segment, preserving the pre-split behavior.

The splitter always runs for Bash commands. Single commands (no operators)
produce one segment and are matched identically to the previous behavior.

## Readonly Bash command auto-allow

After deny checking (deny always wins) and before allow/ask matching, the
hook checks whether ALL segments of a Bash command are read-only. If so,
the command is auto-allowed without needing explicit allow rules.

The readonly command list mirrors Claude Code's `readOnlyValidation.ts`:

* **Simple commands** (generic safety regex `^<cmd>(?:\s|$)[^<>()$\x60|{}&;\n\r]*$`):
  `cal`, `uptime`, `cat`, `head`, `tail`, `wc`, `stat`, `strings`, `hexdump`,
  `od`, `nl`, `id`, `uname`, `free`, `df`, `du`, `locale`, `groups`, `nproc`,
  `basename`, `dirname`, `realpath`, `cut`, `paste`, `tr`, `column`, `tac`,
  `rev`, `fold`, `expand`, `unexpand`, `fmt`, `comm`, `cmp`, `numfmt`,
  `readlink`, `diff`, `true`, `false`, `sleep`, `which`, `type`, `expr`,
  `test`, `getconf`, `seq`, `tsort`, `pr`
* **Two-word commands** (same safety regex): `docker ps`, `docker images`
* **Custom regex commands**: `echo` (no `$`/backticks), `pwd`, `whoami`,
  `ls`, `find` (no `-exec`/`-delete`), `cd`, `jq` (no `-f`/`--from-file`),
  `uniq`, `history`, `alias`, `arch`, `node -v`, `python --version`,
  `python3 --version`

**Path validation**: after a segment matches a readonly regex, all absolute
path arguments are checked against cwd and allowed dirs via
`_pm_path_inside_any_allowed`. Relative paths are assumed to resolve inside
cwd. This prevents `cat /etc/passwd` from being auto-allowed while allowing
`cat src/main.rs`.

Auto-allowed commands are logged with source `passthru-readonly` and reason
`readonly:<first-word>`.

## Allowed directories

The `allowed_dirs` field in passthru.json extends the trusted directory set
for path-based auto-allow. It affects:

* **Mode auto-allow** (`permission_mode_auto_allows`): Read/Edit/Write/Grep/
  Glob/LS tools with paths in any allowed dir are treated the same as files
  inside cwd.
* **Readonly auto-allow** (`readonly_paths_allowed`): absolute path arguments
  in read-only Bash commands are checked against cwd AND each allowed dir.

`load_allowed_dirs` in `hooks/common.sh` reads `allowed_dirs` from all four
rule files, concatenates, and deduplicates. It is separate from `load_rules`
to preserve the `{version, allow, deny, ask}` contract. Bootstrap imports
Claude Code's `additionalAllowedWorkingDirs` from settings and writes them
to `allowed_dirs` in `passthru.imported.json`.

See `docs/rule-format.md` for the schema and `CONTRIBUTING.md` for guidance
on extending `allowed_dirs` support.

## Internal tool auto-allow

Agent, Skill, and Glob are always auto-allowed with an explicit `allow`
decision (not passthrough). This runs before rule loading (step 3b in
`pre-tool-use.sh`) so it is fast and cannot be affected by broken rule files.
These tools are logged with source `passthru-internal`.

ToolSearch, TaskCreate, and other CC-internal tools remain in the step 7
passthrough list and emit `{"continue": true}`.

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
* Changing the overlay UI or keyboard flow: `scripts/overlay-dialog.sh` is the TUI, `scripts/overlay.sh` is the multiplexer dispatcher, and `scripts/overlay-propose-rule.sh` proposes the regex on A/D. Test via `PASSTHRU_OVERLAY_TEST_ANSWER`; see `tests/overlay.bats` for the stub-tmux pattern.
* Changing ask-rule semantics: the merged document-order logic sits in `hooks/common.sh` (`find_first_match`) and `hooks/handlers/pre-tool-use.sh`. Ask rule parsing + validation is in `validate_rules` + `load_rules`. The verifier's conflict and shadowing checks in `scripts/verify.sh` must also cover `ask[]`.
* Adding a new overlay multiplexer backend: add detection + launch lines in `scripts/overlay.sh` (search for the tmux / kitty / wezterm branches) and a stub fixture in `tests/fixtures/overlay/`. The shared detector helper lives in `hooks/common.sh` (`detect_overlay_multiplexer`).
* Adding a new readonly command: add the command to `PASSTHRU_READONLY_COMMANDS` (simple), `PASSTHRU_READONLY_TWO_WORD_COMMANDS` (two-word), or `PASSTHRU_READONLY_CUSTOM_REGEXES` (custom regex) in `hooks/common.sh`. Test via `tests/hook_handler.bats`. See `CONTRIBUTING.md` section "Extending the readonly command list".
* Changing compound command splitting: the splitter is `split_bash_command` in `hooks/common.sh` (inline perl). The per-segment matching logic is `match_all_segments` in the same file. Test via `tests/command_splitting.bats`.
* Working with allowed dirs: see `CONTRIBUTING.md` section "Working with `allowed_dirs`". Key functions are `load_allowed_dirs`, `_pm_path_inside_any_allowed`, and `permission_mode_auto_allows` (5th parameter) in `hooks/common.sh`.
