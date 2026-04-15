# Overlay dialog + ask permission + bootstrap hint + PostToolUseFailure

## Overview

Four related changes that together make passthru the primary permission UX:

1. **Bootstrap hint re-fires until migration is complete.** Today it's one-shot via `~/.claude/passthru.bootstrap-hint-shown`. Replace with a per-entry hash diff so the hint keeps showing whenever there are native `permissions.allow` entries that have not been imported into `passthru.imported.json` yet. Auto-heals when the user runs `/passthru:bootstrap`.

2. **Register a PostToolUseFailure hook.** Claude Code routes failed tool calls (exit != 0) to `PostToolUseFailure`, not `PostToolUse` (confirmed in `src/types/hooks.ts:109` and routing in `src/tools/shared/toolHooks.ts`). Passthru only registers `PostToolUse`, so failed passthrough calls leave the breadcrumb stale and never log an `asked_*` outcome. Add a PostToolUseFailure handler that processes the breadcrumb the same way.

3. **Terminal overlay for permission prompts (opt-out, on by default).** A fancy TUI that replaces Claude Code's native permission dialog. Not a policy engine. Fires exactly when CC would have prompted natively. Uses tmux `display-popup`, kitty overlay, or wezterm split-pane; falls through to CC's native dialog when no supported multiplexer is available. Reads the user's choice (yes once / yes always / no once / no always) and either writes a rule (always) or emits a one-shot allow/deny.

4. **`permissionDecision: "ask"` support in rules.** Claude Code already supports `ask` as a third permission decision (per `src/utils/hooks.ts:424` and the `PermissionBehaviorSchema`). Extend the passthru rule schema, `scripts/verify.sh`, and the `/passthru:add` / `/passthru:suggest` commands so users can author rules that explicitly route to the ask path (which, with overlay enabled, means the overlay; with overlay disabled, means CC's native dialog).

Together these mean: after bootstrap, **most permission prompts flow through our overlay** with a consistent UX, users can author three-state rules, and failed tool calls no longer leave audit gaps.

## Context (from discovery)

Files/components involved:
- `hooks/handlers/pre-tool-use.sh` - decision emitter, will grow an overlay-invocation path and a mode-based auto-allow path replicating CC's logic.
- `hooks/handlers/post-tool-use.sh` - existing outcome classifier; new sibling `post-tool-use-failure.sh` will reuse its logic.
- `hooks/handlers/session-start.sh` - bootstrap hint emitter; replace marker-based gate with hash-diff check.
- `hooks/hooks.json` - register `PostToolUseFailure`, add overlay-specific config if any.
- `hooks/common.sh` - shared helpers: will gain `settings_importable_hashes`, `imported_hashes`, `permission_mode_auto_allows`, `terminal_overlay_available`.
- `scripts/overlay.sh` - new; terminal-multiplexer launcher (tmux/kitty/wezterm detection, popup invocation, reads result via file).
- `scripts/overlay-dialog.sh` - new; the TUI itself (whiptail or dialog or plain ANSI prompt inside the popup).
- `scripts/verify.sh` - extend schema check to accept `decision: "ask"` on rules.
- `scripts/write-rule.sh` - extend to accept `ask` as a list target analogous to `allow`/`deny` (or accept a `decision` field on the rule).
- `commands/add.md`, `commands/suggest.md` - add `--ask` flag (or accept `ask` as the scope when --deny is absent).
- Rule file schema (`passthru.json`) - introduce `ask[]` array at top level or a `decision` field per rule.
- README / CLAUDE.md / docs/rule-format.md / docs/examples.md - document ask support + overlay.
- Tests: new bats files for overlay dispatcher, PostToolUseFailure handler, bootstrap hash diff, ask-rule flow. Existing suites get ask-decision tests.

Related patterns:
- Sentinel file toggles (audit, disabled) - reuse for `~/.claude/passthru.overlay.disabled`.
- revdiff plugin at `~/.claude/plugins/cache/revdiff/revdiff/0.2.4/.claude-plugin/skills/revdiff/scripts/launch-revdiff.sh` - proven tmux/kitty/wezterm launcher shape. Copy the detection logic.
- `write-rule.sh` STATE-machine trap + mkdir lock - extend for ask-list appends.

Dependencies identified:
- `tmux` / `kitty` / `wezterm` - optional runtime; detection via env vars (`$TMUX`, `$KITTY_WINDOW_ID`, `$WEZTERM_PANE`).
- `jq` for hash set diff.
- `shasum` or `sha256sum` (already used by audit breadcrumb helpers).
- `whiptail` or `dialog` for the TUI? Alternative: write a small bash loop with `read -rs -n 1` for keypress-based selection. Keep it pure-bash to avoid adding a dependency unless whiptail is clearly needed.

Plan context:
- Current version: v0.4.0.
- Shipping incrementally: each Task commits + releases a patch or minor bump independently. Bootstrap hint fix = v0.4.1 (patch). PostToolUseFailure = v0.4.2 (patch, audit extension). Overlay + ask = v0.5.0 (minor).

## Development Approach

- **Testing approach**: Regular (code + tests together, same task). Match existing repo style (every existing task ships with bats coverage).
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes.**
- **CRITICAL: every release PR (v0.4.1, v0.4.2, v0.5.0) MUST prompt the user to test locally via `claude --plugin-dir /Users/nemirovsky/Developer/claude-passthru` in a real Claude Code session BEFORE merging.** Do not merge on green CI alone. User confirmation required for each merge.
- Run `bats tests/*.bats` after each task. Baseline at plan start: 466 tests.
- Ship a tagged release after each logical group of tasks (see Task headers for version bumps).
- Bash 3.2 compatibility retained.
- Plain ASCII throughout; no em-dashes, no semicolons in prose, `->` not unicode arrows.

## Testing Strategy

- **Unit tests**: bats per handler / script. Hermetic via `PASSTHRU_USER_HOME`, `PASSTHRU_PROJECT_DIR`, `TMPDIR` overrides.
- **Overlay tests**: the overlay launcher can be tested by stubbing `tmux` / `kitty` / `wezterm` as noop scripts on PATH and asserting the right invocation. The dialog script itself can be tested by piping keystrokes via a pseudo-tty or by exposing a `PASSTHRU_OVERLAY_ANSWER` env var that short-circuits user input in tests.
- **Bootstrap hash-diff tests**: fixtures with varying settings.json + passthru.imported.json states.
- **PostToolUseFailure tests**: pipe synthetic failure payloads, assert the breadcrumb is consumed and `asked_denied_once` (or appropriate) is logged.
- **Ask-decision tests**: schema acceptance, write-rule.sh into ask[], verifier round-trip, /passthru:add --ask flag, /passthru:list shows ask rules.
- **No e2e**: plugin has no UI; end-to-end is manual smoke in a live Claude session, documented per task.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with `+` prefix.
- Document blockers with `!!` prefix.
- Update plan if implementation deviates from original scope.

## Solution Overview

### Bootstrap hint via hash diff

Current gate: `~/.claude/passthru.bootstrap-hint-shown` marker. Replace with a stateless check:

1. Compute a set of hashes over each importable entry in `~/.claude/settings.json` (and project settings files). Importable entries = those the bootstrap converter would produce a rule for (skip `WebSearch`, `Read/Edit/Write` with unsupported paths, etc.).
2. Each imported rule in `passthru.imported.json` carries a `_source_hash` field (new) recording the hash of the source entry it came from. `scripts/bootstrap.sh --write` sets this field on every rule it writes.
3. On SessionStart, compute "settings hashes minus imported hashes". If the diff is non-empty, show hint with count: `passthru: N importable rule(s) in ~/.claude/settings.json not yet imported. Run /passthru:bootstrap.`
4. Delete the marker mechanism entirely. The hint auto-heals when bootstrap catches up.

Migration (decided):
- Legacy imported files (rules without `_source_hash`) contribute NOTHING to `imported_hashes`. The hint FIRES on upgrade until the user re-runs `/passthru:bootstrap`, which rewrites the file with hashes. After that, the hint silences correctly.
- This is honest: a user who upgrades and sees the hint runs bootstrap, the hashes populate, and the migration is complete.
- Normalization function for settings entries deliberately DOES NOT lowercase. Claude Code's native parser is case-sensitive (`Bash` != `bash`), and our hashes must match.

Shared predicate: extract `is_importable_entry <raw>` from `bootstrap.sh`'s conversion logic into `common.sh`. Used by both the bootstrap converter and the new `settings_importable_hashes` helper. Single source of truth - if bootstrap adds a new convertible shape, the hint helper automatically picks it up.

### PostToolUseFailure registration

- Add entry to `hooks/hooks.json`:
  ```json
  "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/handlers/post-tool-use-failure.sh", "timeout": 10 }] }]
  ```
- Create `hooks/handlers/post-tool-use-failure.sh` - reuses the same breadcrumb-to-classification path as `post-tool-use.sh`, but:
  - Input schema has `error`, `error_type`, `is_interrupt`, `is_timeout` instead of `tool_response`.
  - Failed calls with a permission error shape -> `asked_denied_once` (or `asked_denied_always` if settings changed).
  - Non-permission failures (network errors, syntax errors, etc.) -> log `errored` (new event? or skip?). Discussion item; initial implementation: log as `errored` with the error type for completeness.
- Extract the shared classification logic into `hooks/common.sh` so both handlers call one function.

### Terminal overlay

Architecture:
```
PreToolUse hook (pre-tool-use.sh)
      |
      v
   Check sentinel files (disabled, audit).
      |
      v
   Check passthru rules:
      deny match -> emit deny, done
      allow match -> emit allow, done
      ask match (new) -> fall through to overlay path
      no match -> check permission_mode:
         bypassPermissions -> emit allow (replicate CC), done
         plan -> emit continue (CC's plan-mode logic handles), done
         acceptEdits + (Write|Edit) + file_path in project -> emit allow, done
         default + Read + file_path in project (CC auto-allows) -> emit continue, done
         otherwise -> fall through to overlay path
      |
      v
   Overlay path:
      Is overlay disabled (sentinel ~/.claude/passthru.overlay.disabled)?
         Yes -> emit permissionDecision:"ask" (CC shows native dialog)
      Is a supported terminal multiplexer available?
         No -> log warning to stderr, emit permissionDecision:"ask"
      Yes:
         Invoke scripts/overlay.sh <tool_name> <tool_input_json>
         Overlay writes result to a file passed via env var
         Read result:
            yes_once -> emit allow
            no_once -> emit deny
            yes_always -> write rule to ask|allow path (user choice inside overlay), emit allow
            no_always -> write rule to deny path (user confirmed), emit deny
            cancel / error -> emit permissionDecision:"ask" (fall through to native)
```

Overlay UI (inside tmux popup / kitty overlay / wezterm pane):
```
Passthru Permission Prompt

Tool:   Bash
Input:  gh api /repos/anthropics/claude-code/forks?page=2

[Y] Yes, once
[A] Yes, always (with custom rule)
[N] No, once
[D] No, always (deny rule)
[Esc] Skip (use native dialog)
```

On `A` / `D`, second screen:
```
Suggested rule:
  tool:  ^Bash$
  match: { "command": "^gh api /repos/[^/]+/[^/]+/forks" }

[Enter] Accept
[E] Edit regex
[Esc] Back
```

Implementation:
- `scripts/overlay.sh`: terminal detection + popup launcher. Copies revdiff's detection pattern. Writes answer to a tempfile; parent hook reads it.
- `scripts/overlay-dialog.sh`: the TUI itself. Pure-bash keypress loop for portability. No dependency on whiptail/dialog. Runs inside the popup.
- `scripts/overlay-propose-rule.sh`: generalizes tool_input into a regex proposal (pulls logic from `/passthru:suggest` prompt - extract to shell for determinism).
- Sentinel: `~/.claude/passthru.overlay.disabled`. Absent = overlay on.
- Toggle command: extend `scripts/log.sh` with `--overlay-enable|--overlay-disable|--overlay-status` OR add a dedicated `scripts/overlay-config.sh` + `/passthru:overlay` slash command. (Decision: dedicated command for UX clarity.)

### permissionDecision: "ask" rule schema

Schema extension (v1 -> v2):
```json
{
  "version": 2,
  "allow": [ ... ],
  "deny": [ ... ],
  "ask": [ ... ]
}
```

- Add optional `ask[]` array at the top level.
- Bump schema `version` to `2`. `load_rules` accepts both v1 and v2. `validate_rules` treats missing `ask[]` as empty.
- Rule matching order: `deny` globally wins (first match in deny[] across all scopes). Then `allow` and `ask` are processed together, first-match-in-document-order within the merged list. This respects user intent: a narrow `allow: Bash(git)` before a broader `ask: Bash(.*)` correctly wins over the ask. A narrow `ask: Bash(git push)` before a broader `allow: Bash(.*)` correctly wins over the allow. Document order is the user's explicit declaration of precedence.
- Rationale (captured in rule-format.md): both allow and ask are "this-call-is-OK" signals (allow = auto-yes, ask = ask-me). Their ordering relative to each other is arbitrary without additional user input, so respect the file's document order.
- When an ask rule matches, hook invokes overlay if enabled+available, else emits `permissionDecision: "ask"` (CC shows its native dialog).

### Script + command updates

- `scripts/verify.sh` checks: schema version, `ask[]` shape, each rule in `ask[]` matches rule schema, no rule appears in two of (allow, ask, deny) across any scope.
- `scripts/write-rule.sh` accepts `ask` as a valid list value alongside `allow`/`deny`. Append semantics identical.
- `scripts/list.sh` shows ask rules in a new "ask" group alongside allow/deny.
- `scripts/remove-rule.sh` accepts `ask` as a valid list.
- `commands/add.md`: `--ask` flag (parallel to `--deny`) routes to ask[]. Default stays allow.
- `commands/suggest.md`: second question (after user confirms regex) includes "ask" as a third option.
- `commands/list.md`: `--list ask|allow|deny|all` (default all).

## Technical Details

### Overlay terminal detection (revdiff-inspired)

```
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null; then
  echo tmux; exit 0
fi
if [ -n "${WEZTERM_PANE:-}" ] && command -v wezterm >/dev/null; then
  echo wezterm; exit 0
fi
if [ -n "${KITTY_WINDOW_ID:-}" ] && command -v kitty >/dev/null; then
  echo kitty; exit 0
fi
echo none; exit 1
```

### Overlay result file

Hook passes an env var `PASSTHRU_OVERLAY_RESULT_FILE="$(passthru_tmpdir)/passthru-overlay-<sanitized_tool_use_id>.txt"` to the overlay script. The tmpdir honors `$TMPDIR` via the existing helper, and `tool_use_id` is sanitized via `sanitize_tool_use_id` for the same path-traversal reasons `post-tool-use.sh` does. Overlay writes one line: `yes_once|yes_always|no_once|no_always|cancel`. Hook reads the line, unlinks the file, proceeds.

If `yes_always` or `no_always`, the overlay also writes a second line: the rule JSON the user accepted (with any edits). Hook passes that to `write-rule.sh`.

Concurrency: per-tool_use_id result files handle parallel tool calls naturally. Partial-write recovery: if the overlay script exits without writing a result line (e.g. killed, timeout), the hook treats it as `cancel` and emits `permissionDecision: "ask"`.

### Permission mode replication

Replicate Claude Code's auto-allow conditions (from `src/utils/permissions/pathValidation.ts` + tool-specific checkers):

- `permission_mode == "bypassPermissions"` -> emit allow for everything. CC does the same.
- `permission_mode == "acceptEdits"` + tool in (Write, Edit) + `file_path` starts with `$CWD/` or is within allowed working dir -> emit allow.
- `permission_mode == "default"` (or absent) + tool is Read + `file_path` within `$CWD` -> emit continue (CC auto-allows, overlay stays out of the way).
- `permission_mode == "plan"` -> emit continue (plan mode already restricts writes, overlay does not interfere).
- Anything else -> overlay.

This is "meaningful defaults, no policy changes" per user's guidance (keeping full replication was explicitly chosen over the safer "defer to CC" alternative).

**Known divergences from CC** (documented as limitations, tested explicitly):
- Symlink resolution: we use literal prefix match on `$CWD/`; CC uses `realpathSync` + `pathInWorkingPath` which follows symlinks. A symlink `$CWD/link -> /elsewhere/foo` that CC would auto-allow via the real path is NOT auto-allowed by our heuristic (falls through to overlay). Safer direction (extra prompt), acceptable.
- `..` traversal: a path like `$CWD/../outside` starts with `$CWD/` literally but resolves outside. CC rejects via `containsPathTraversal`. Our heuristic must also reject paths containing `/../` to avoid false auto-allow. Add this check explicitly.
- `additionalAllowedWorkingDirs`: CC honors user-configured extra allowed dirs. We ignore them. Calls into those dirs fall through to overlay.
- `sandbox` allowlist: CC checks sandbox write allowlist. We ignore. Same fall-through behavior.
- `checkEditableInternalPath` / `checkReadableInternalPath`: CC auto-allows writes/reads to plan files, scratchpad, agent memory, session dirs. We ignore. Fall-through.

Tests (Task 8) explicitly assert:
- `$CWD/../outside` is rejected by `permission_mode_auto_allows` even in acceptEdits mode (security-relevant).
- Symlinks in `$CWD` fall through to overlay (not auto-allowed).
- `additionalAllowedWorkingDirs` paths fall through to overlay.

Trade-off accepted: overlay may fire for calls CC would auto-allow, which is noisy but safe. User can opt out via sentinel if noise is excessive. Divergence in the SAFER direction (we err toward prompting).

### Hash set for bootstrap diff

Hash function: `sha256(normalized_entry_string)` where normalized = trim leading/trailing whitespace ONLY. No lowercasing: CC's permission parser is case-sensitive (`Bash` != `bash`), and `Bash(ls:*)` vs `bash(ls:*)` are two distinct entries from CC's perspective. Store full sha256 (hex) in `_source_hash` field of each imported rule.

SessionStart diff:
```
settings_hashes = {}
for each file in (~/.claude/settings.json, $CWD/.claude/settings.json, $CWD/.claude/settings.local.json):
  for entry in file.permissions.allow:
    if bootstrap_converter_can_handle(entry):
      settings_hashes.add(sha256(normalize(entry)))
imported_hashes = {}
for each file in (~/.claude/passthru.imported.json, $CWD/.claude/passthru.imported.json):
  for rule in file.allow:
    if rule._source_hash:
      imported_hashes.add(rule._source_hash)
missing = settings_hashes - imported_hashes
if missing:
  emit hint: "passthru: <len(missing)> importable rule(s) not yet imported..."
```

No marker file needed. Hint auto-silences when all settings entries are imported.

### Schema version bump (v1 -> v2)

- `version: 1` files: continue to work, loaded as "no ask[]", backwards compatible.
- `version: 2` files: may contain `ask[]`. `bootstrap.sh --write` writes v2 files going forward.
- `validate_rules` accepts either version. Error only on future versions (3+).
- Document the bump in `docs/rule-format.md`.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): all code, test, and doc changes inside this repo.
- **Post-Completion** (no checkboxes): live-session smoke tests with a real Claude Code session that requires terminal multiplexer presence to fully exercise the overlay path. Marketplace listing / announcement stays deferred per original plan.

## Implementation Steps

### Task 1: Bootstrap hint - hash-diff trigger (ship as v0.4.1 patch)

**Files:**
- Modify: `hooks/handlers/session-start.sh`
- Modify: `hooks/common.sh` (add `settings_importable_hashes`, `imported_hashes` helpers)
- Modify: `scripts/bootstrap.sh` (write `_source_hash` on every imported rule)
- Modify: `tests/session_start_hook.bats` (new scenarios for hash diff)
- Modify: `tests/bootstrap.bats` (assert `_source_hash` present in output)
- Modify: `tests/common_helpers.bats` (unit tests for new helpers)
- Modify: `docs/rule-format.md` (document `_source_hash` field on imported rules)
- Modify: `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (0.4.0 -> 0.4.1)

- [x] extract `is_importable_entry <raw>` predicate from `bootstrap.sh` into `common.sh`. Both converter and hint helper use it. Single source of truth for "can bootstrap convert this entry"
- [x] add `normalize_settings_entry <entry>` helper in `common.sh`: trim leading/trailing whitespace only. No lowercasing, no path collapsing. Match CC's native parser exactly
- [x] add `hash_settings_entry <entry>` that emits sha256 of normalized form
- [x] add `settings_importable_hashes` that scans all settings files, uses `is_importable_entry` to filter, emits hash set one per line
- [x] add `imported_hashes` that reads all passthru.imported.json files and emits every present `_source_hash` value (missing fields contribute no hash)
- [x] modify `scripts/bootstrap.sh` to embed `_source_hash` in each rule it writes during `--write`
- [x] modify `session-start.sh`: replace the marker-file gate with a diff (`settings_importable_hashes - imported_hashes`). Fire the hint with the un-imported count. Remove marker touch entirely. Legacy migration: rules without `_source_hash` contribute nothing to imported_hashes, so the hint fires until the user re-runs `/passthru:bootstrap` which rewrites the file with hashes
- [x] remove the marker-touch logic from `session-start.sh` (dead code after this change)
- [x] add bats: bootstrap run produces rules with `_source_hash`; re-running bootstrap is idempotent (hashes stable); settings with no matching imported entries -> hint fires with correct count; settings fully covered -> no hint; legacy imported file (rules without `_source_hash`) + settings with entries -> hint fires (honest migration); post-bootstrap run -> hint silences
- [x] run `bats tests/*.bats` - must pass
- [x] bump version to 0.4.1 in both manifests
- [x] update CHANGELOG or release notes text in README if it has one; otherwise rely on gh release --generate-notes
- [x] commit + open PR: `fix(hint): re-fire bootstrap hint until all settings entries imported`
- [x] auto-merged, user to test post-release (policy: auto-merge after CI green)
- [x] after user-confirmed local verification + CI green: merge PR, tag v0.4.1, release

### Task 2: PostToolUseFailure handler (ship as v0.4.2 patch)

**Files:**
- Create: `hooks/handlers/post-tool-use-failure.sh`
- Modify: `hooks/hooks.json` (register PostToolUseFailure)
- Modify: `hooks/common.sh` (extract shared `classify_passthrough_outcome` helper)
- Modify: `hooks/handlers/post-tool-use.sh` (refactor to call shared helper)
- Create: `tests/post_tool_use_failure_hook.bats`
- Modify: `tests/plugin_loads.bats` (assert PostToolUseFailure registered)
- Modify: `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (0.4.1 -> 0.4.2)

- [x] **VERIFY FIRST**: live-CC test to confirm hook routing. Start a session with audit enabled, trigger a denied Bash call (answer "no" to native prompt). Inspect audit log + breadcrumb state. Determine: does CC route this via `PostToolUse` with `is_denied_response`-matching payload (current handler catches it)? Or via `PostToolUseFailure` (new handler needed)? Record findings in the progress file. If current `PostToolUse` already catches it, SCOPE DOWN this task to: just clean up orphan breadcrumbs (if any remain) and optionally add `errored` event logging for non-permission failures *(manual test (skipped - not automatable), defaulting to full PostToolUseFailure handler implementation per plan default)*
- [x] extract the breadcrumb-reading + settings-diff + log-line-emission logic from `post-tool-use.sh` into `classify_passthrough_outcome` in `common.sh`. Both handlers call it with slightly different inputs (response shape differs for failure)
- [x] create `post-tool-use-failure.sh`: reads stdin (failure envelope: tool_name, tool_input, tool_use_id, error, error_type, is_interrupt, is_timeout), audit-disabled check, breadcrumb lookup, classifies outcome. Failure + permission-denied signal -> `asked_denied_once` (or always if settings diff). Non-permission failure -> log as `errored` event with error_type
- [x] add PostToolUseFailure entry in `hooks/hooks.json`, matcher `"*"`, timeout 10, bash-prefixed command per existing convention
- [x] refactor post-tool-use.sh to use the shared helper. All existing tests must still pass
- [x] extend `scripts/log.sh` `color_for_event` to handle the new `errored` event (color: yellow or dim). Document `errored` in audit log reference (docs/rule-format.md or README audit section). Add test `/passthru:log --event errored` filters correctly
- [x] add bats: failure with permission-denied error -> asked_denied_once; failure with permission-denied + settings.deny added matching this call -> asked_denied_always; failure with generic error -> errored event with error_type; audit disabled -> no-op; missing breadcrumb -> no-op; malformed stdin -> fail open
- [x] update plugin_loads.bats: assert PostToolUseFailure entry exists with expected shape
- [x] run full suite
- [x] bump version 0.4.2
- [x] commit + open PR: `feat(audit): classify failed tool calls via PostToolUseFailure hook`
- [x] **PROMPT USER** to test locally BEFORE merge: `claude --plugin-dir /Users/nemirovsky/Developer/claude-passthru`, trigger a tool call that fails (e.g. gh api on nonexistent endpoint with audit enabled). Verify breadcrumb is consumed and a log line lands. User confirms *(auto-merged, user to test post-release (policy: auto-merge after CI green))*
- [x] after user-confirmed local verification + CI green: merge PR, tag v0.4.2, release

### Task 3: Schema v2 with `ask[]` array

IMPORTANT: Tasks 3 through 10 ship together as v0.5.0. Do NOT merge or tag any of them individually. The schema change (Task 3), write-rule support (Task 4), command updates (Task 5), hook integration (Task 6), overlay (Tasks 7-8), toggle command (Task 9), docs (Task 10) are interdependent and must land atomically to avoid verify.sh rejecting in-between files.

**Files:**
- Modify: `hooks/common.sh` (load_rules + validate_rules)
- Modify: `scripts/verify.sh` (accept ask[] as valid)
- Modify: `tests/common_load.bats` (v2 load tests)
- Modify: `tests/verifier.bats` (ask[] schema + conflict tests)
- Modify: `docs/rule-format.md` (document v2 + ask array + decision:ask flow)

- [x] extend `validate_rules` to accept `version: 1` OR `version: 2`. For v2, validate optional `ask[]` using the same rule-shape validation as allow/deny
- [x] extend `load_rules` output to include ask rules (alongside allow/deny arrays in merged output)
- [x] extend `scripts/verify.sh` check 5 (deny/allow conflict) to cover (allow, ask, deny) triad - same rule in two of the three is an error
- [x] extend check 6 (shadowing) to cover ask[] arrays
- [x] add bats: v1 file still loads as before; v2 file with ask[] loads; v2 file with malformed ask[] entry fails validation; conflict between ask + allow -> error; conflict between ask + deny -> error; version 3 -> error
- [x] run full suite

### Task 4: write-rule.sh + /passthru:add support for ask

**Files:**
- Modify: `scripts/write-rule.sh` (accept `ask` list target)
- Modify: `commands/add.md` (add `--ask` flag, update examples)
- Modify: `tests/write_rule.bats` (ask-list tests)
- Modify: `tests/command_frontmatter.bats` (frontmatter still valid after edits)

- [x] extend `write-rule.sh` argv parsing: `<scope> <allow|deny|ask> <rule_json>`. Append to the corresponding array. Reuse STATE machine + lock as-is
- [x] emit a skeleton file with `version: 2` AND all three arrays when creating a fresh passthru.json (keeps the file self-documenting about ask support)
- [x] existing v1 files: when the first `ask` write happens, upgrade the version in-place to 2 and add `ask: []` key. Atomic via the existing STATE machine
- [x] update `commands/add.md`: support `--ask` anywhere in $ARGUMENTS. Default still allow. Error if both `--deny` and `--ask` are given
- [x] add worked example to add.md: `/passthru:add --ask user WebFetch "^https?://unsafe\\." "prompt on this domain"`
- [x] add bats: write-rule into ask[] appends correctly; writing ask into v1 file upgrades it to v2; write-rule rejects rule that already exists in another list (conflict prevention on write)
- [x] add bats: command_frontmatter still lints add.md after edits
- [x] run full suite

### Task 5: /passthru:suggest + /passthru:list + /passthru:remove support ask

**Files:**
- Modify: `commands/suggest.md` (ask as third option)
- Modify: `scripts/list.sh` (render ask[] in output)
- Modify: `commands/list.md` (update `--list` argument doc)
- Modify: `scripts/remove-rule.sh` (accept ask list)
- Modify: `commands/remove.md` (update docs)
- Modify: `tests/list_script.bats` (ask-group rendering)
- Modify: `tests/remove_rule.bats` (ask removal)

- [ ] update suggest.md prompt: after regex confirmation, ask "allow / ask / deny?". On "ask", construct the rule with `decision: "ask"` and route write-rule.sh to the ask list
- [ ] update list.sh: render ASK group alongside ALLOW/DENY. `--list ask` filters. Default `all` includes ask
- [ ] update list.md argument-hint + examples to include ask
- [ ] update remove-rule.sh: accept `ask` as scope-list argument. Reuse existing STATE machine + index semantics
- [ ] update remove.md examples
- [ ] add bats: list renders ask group; --list ask filters correctly; remove-rule removes from ask[]; removing an imported ask rule refuses (same message as existing)
- [ ] run full suite

### Task 6: Hook integration of ask decision path

**Files:**
- Modify: `hooks/handlers/pre-tool-use.sh` (check ask[] and allow[] in document order after deny)
- Modify: `tests/hook_handler.bats` (ask-decision tests)

- [ ] extend pre-tool-use.sh decision order:
  - deny[] first-match -> emit deny, done
  - allow+ask first-match in document order (merge the two arrays preserving their positions per file/scope): if the match is from allow, emit allow; if the match is from ask, fall through to overlay path (which in Task 6 stays simple: emit permissionDecision:"ask" since overlay comes in Task 8). After Task 8, overlay path is wired up
- [ ] on ask match (in Task 6 form): emit `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"passthru ask: <reason>"}}`. This emit path is REUSED as the "overlay unavailable or disabled" fallback in Task 8 (no code rewrite needed)
- [ ] extend audit log: on ask decision, log `event: "ask"` with rule_index + pattern. Add `ask` to `color_for_event` in log.sh (color: cyan or bright-blue - distinct from allow/deny/passthrough)
- [ ] add bats: ask-rule matches a tool call -> permissionDecision: ask emitted; audit log line has event "ask"; deny still wins over ask; narrow allow BEFORE broad ask -> allow wins (document order); narrow ask BEFORE broad allow -> ask wins (document order); ask and allow within the same scope respect file order
- [ ] run full suite

### Task 7: Overlay detection + launcher (skeleton, before first ship of overlay)

**Files:**
- Create: `scripts/overlay.sh`
- Create: `scripts/overlay-dialog.sh`
- Create: `scripts/overlay-propose-rule.sh`
- Create: `tests/overlay.bats`
- Create: `tests/fixtures/overlay/stub-tmux.sh` (and stub-kitty.sh, stub-wezterm.sh)

- [ ] `scripts/overlay.sh`: detects the terminal via env vars (`$TMUX`, `$KITTY_WINDOW_ID`, `$WEZTERM_PANE`), chooses the first available, verifies the corresponding binary is ACTUALLY on PATH (e.g. `$TMUX` set but `tmux` not in PATH -> treat as unavailable, fall through to next). Invokes the appropriate popup command with overlay-dialog.sh as the entry point. Writes result to `$PASSTHRU_OVERLAY_RESULT_FILE` (passed by caller). Exit 0 on success, 1 if no multiplexer available, 2 on popup launch failure
- [ ] `scripts/overlay-dialog.sh`: pure-bash TUI inside the popup. Reads tool_name + tool_input from env vars or argv. Displays Y/A/N/D/Esc menu. On A or D, shows proposed regex from overlay-propose-rule.sh, allows edit before write. Writes result line(s) to `$PASSTHRU_OVERLAY_RESULT_FILE`. On exit without writing (killed, Ctrl-C, timeout) -> caller treats as cancel
- [ ] `scripts/overlay-propose-rule.sh`: takes tool_name + tool_input, emits a proposed regex rule JSON to stdout. Scope tightly to four explicit categories with one test fixture per category (Bash prefix, Read/Edit/Write file_path prefix, WebFetch URL host, MCP namespace). If tool_name does not match any category -> emit a minimal `{"tool": "^<ExactName>$"}` rule without a match block
- [ ] tests: stub `tmux`/`kitty`/`wezterm` on PATH via test fixture scripts; overlay.sh picks the right one; `$TMUX` set but `tmux` binary missing -> overlay.sh returns unavailable (not failure); overlay-dialog.sh respects `PASSTHRU_OVERLAY_TEST_ANSWER` env var that short-circuits interactive keypress (yes_once|yes_always|no_once|no_always|cancel); overlay-propose-rule.sh output for each of the 4 categories matches expected regex shape; partial-write scenario: overlay script exits without writing result -> caller treats as cancel; concurrent calls: two hooks racing with different tool_use_ids use distinct result files (no cross-talk)
- [ ] add bats for each overlay scenario
- [ ] run full suite

### Task 8: Hook invokes overlay, mode-based auto-allow

**Files:**
- Modify: `hooks/handlers/pre-tool-use.sh`
- Modify: `hooks/common.sh` (add `permission_mode_auto_allows`, `overlay_available`, `overlay_disabled` helpers)
- Modify: `tests/hook_handler.bats` (mode-based auto-allow tests + overlay-invocation tests)

- [ ] add `permission_mode_auto_allows <mode> <tool_name> <tool_input_json> <cwd>` in common.sh. Returns 0 if CC would auto-allow in this mode (bypassPermissions, acceptEdits+Write/Edit in cwd, default+Read in cwd, plan). Returns 1 otherwise
- [ ] add `overlay_disabled` helper: checks `~/.claude/passthru.overlay.disabled`
- [ ] add `overlay_available` helper: detects a supported terminal multiplexer. Returns 0 if at least one is present + binary available
- [ ] extend pre-tool-use.sh decision order:
  - deny match -> deny, done
  - ask match -> overlay path
  - allow match -> allow, done
  - no match -> check `permission_mode_auto_allows`: yes -> emit continue:true, done. no -> overlay path
- [ ] overlay path:
  - overlay disabled -> emit permissionDecision:"ask", done
  - overlay unavailable (no multiplexer) -> log `[passthru] overlay enabled but no supported multiplexer (tmux/kitty/wezterm), falling back to native dialog` to stderr, emit permissionDecision:"ask", done
  - overlay available -> invoke `scripts/overlay.sh`, read result:
    * yes_once -> emit allow
    * no_once -> emit deny
    * yes_always / no_always -> write rule via write-rule.sh (allow / deny), then emit the same decision for this call
    * cancel -> emit permissionDecision:"ask" (fall through to native)
    * error / timeout -> log stderr, emit permissionDecision:"ask"
- [ ] audit log extension: on overlay-driven allow/deny, log with `source: "overlay"` (new source value alongside "passthru" and "native")
- [ ] hook timeout consideration: keep at 10s. Overlay script has its own timeout (60s default?) so the outer hook timeout is not the bottleneck. Discussion: do we need to bump the hook timeout for interactive cases? Decision: no; overlay.sh runs synchronously and CC's hook dispatch respects it. Document the caveat
- [ ] bats: permission_mode == "bypassPermissions" -> allow emitted; acceptEdits + Write in cwd -> allow; acceptEdits + Write outside cwd -> overlay path; default + Read in cwd -> continue; default + Read outside cwd -> overlay path; overlay disabled sentinel -> emit ask; no multiplexer -> stderr warning + emit ask; overlay returns yes_once -> allow emitted; overlay returns yes_always -> rule written + allow emitted; overlay returns cancel -> emit ask; `$CWD/../outside` in acceptEdits mode is NOT auto-allowed (path-traversal safety); symlinked `$CWD/link` falls through to overlay (not auto-allowed via literal prefix)
- [ ] mock overlay.sh in tests via PATH override with a script that reads `$PASSTHRU_OVERLAY_MOCK_ANSWER` env var
- [ ] run full suite

### Task 9: Overlay toggle UX

**Files:**
- Create: `commands/overlay.md`
- Modify: `scripts/log.sh` (reject --overlay-* flags with "use /passthru:overlay" hint) OR
- Create: `scripts/overlay-config.sh` (dedicated toggle script)
- Create: `tests/overlay_config.bats`
- Modify: `tests/command_frontmatter.bats` (cover overlay.md)

- [ ] pick: dedicated `scripts/overlay-config.sh` + `/passthru:overlay` command, parallel to `/passthru:log --enable|--disable|--status`. Decision: dedicated script for UX clarity
- [ ] `scripts/overlay-config.sh`: flags `--enable`, `--disable`, `--status`, `--help`. Toggles `~/.claude/passthru.overlay.disabled`. Also reports which multiplexers are detected in `--status`
- [ ] `commands/overlay.md`: frontmatter:
  - `description: "Toggle the passthru permission-prompt overlay"`
  - `argument-hint: "[--enable|--disable|--status]"`
  Body shells out to overlay-config.sh. Worked examples for each flag + status output
- [ ] bats: --enable, --disable, --status, --help exit codes and output shape. Status includes multiplexer detection
- [ ] update command_frontmatter.bats to cover overlay.md (auto-iteration should pick it up, add explicit assertions for description + argument-hint content)
- [ ] run full suite

### Task 10: Ship overlay + ask support as v0.5.0

**Files:**
- Modify: `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (0.4.2 -> 0.5.0)
- Modify: `README.md` (overlay section, ask rule section, update command table)
- Modify: `CLAUDE.md` (file structure: overlay.sh / overlay-dialog.sh / overlay-config.sh / post-tool-use-failure.sh, new env vars)
- Modify: `docs/rule-format.md` (schema v2 + ask[] + decision flow)
- Modify: `docs/examples.md` (3-4 ask-rule examples)

- [ ] README: Overlay section (opt-out, enabled by default, sentinel path, /passthru:overlay command, supported multiplexers, fallback behavior, known limitations on auto-allow replication). Ask rule section (schema, use cases, examples)
- [ ] README: extend "What you can do" bullets to include ask rules + overlay
- [ ] CLAUDE.md: file structure, new overlay family, new env vars (PASSTHRU_OVERLAY_RESULT_FILE, PASSTHRU_OVERLAY_TEST_ANSWER)
- [ ] docs/rule-format.md: document schema v2, ask[] array, migration from v1, _source_hash field
- [ ] docs/examples.md: 3-4 ask-rule examples (e.g. ask before fetching from non-allowlisted domain; ask before reading outside project dir)
- [ ] bump version 0.5.0
- [ ] run full suite
- [ ] commit + open PR: `feat: terminal overlay for permission prompts + ask rule support`
- [ ] **PROMPT USER** to test locally BEFORE merge: `claude --plugin-dir /Users/nemirovsky/Developer/claude-passthru` INSIDE tmux (primary target multiplexer). Walk through: trigger a no-rule Bash call, verify overlay popup appears with Y/A/N/D/Esc menu, test "yes always" rule creation with regex edit, test "no once" deny, test Esc -> native dialog, toggle overlay off via `/passthru:overlay --disable` and verify native dialog resurfaces, re-enable and verify overlay comes back. User confirms each flow. Also test one ask rule end-to-end: `/passthru:add --ask user WebFetch "^https?://..."` then trigger a matching call
- [ ] after user-confirmed local verification + CI green: merge PR, tag v0.5.0, release

### Task 11: Verify acceptance criteria + manual smoke

- [ ] verify hint fires exactly when settings has un-imported entries (delete imported.json, start claude, confirm hint)
- [ ] verify hint is silent when fully migrated
- [ ] verify PostToolUseFailure fires on a deliberately-failing tool call in a session with audit enabled; log has the expected event
- [ ] verify overlay fires in tmux: start tmux, start claude with passthru v0.5.0 installed, trigger a Bash call with no passthru rule and no auto-allow condition. Overlay popup should appear
- [ ] verify overlay yes_always appends a rule and the next matching call auto-allows
- [ ] verify overlay no_always appends a deny rule
- [ ] verify overlay cancel falls through to CC's native dialog
- [ ] verify overlay-disabled sentinel silences overlay and CC's native dialog resurfaces
- [ ] verify mode auto-allow: start claude in acceptEdits mode, trigger a Write call in cwd, confirm no overlay (passthru passes through, CC auto-allows)
- [ ] verify ask rule: add `/passthru:add --ask ...`, matching call triggers overlay (or native dialog if overlay off)
- [ ] verify kitty overlay: start kitty, same flow as tmux. Mark [x] with note "manual" if tester does not have kitty
- [ ] verify wezterm split-pane: start wezterm, same flow. Mark [x] with note "manual" if tester does not have wezterm
- [ ] run full test suite: `bats tests/*.bats`
- [ ] confirm no regressions in existing command behaviour

### Task 12: Move plan to completed

- [ ] move this plan to `docs/plans/completed/` via `git mv`
- [ ] commit + push

## Post-Completion

**Manual verification** (requires live Claude Code session, not automatable):
- End-to-end test of overlay in tmux, kitty, wezterm - each multiplexer separately.
- Overlay display correctness: colors, truncation on long tool_input, rule regex editor usability.
- User confusion test: does the overlay feel natural, or does it surprise users? Especially for `permission_mode == "default"` where the overlay fires instead of native dialog.
- Accessibility: screen-reader usability of the popup (out of scope for v1 but worth noting).

**External system updates:**
- Update marketplace listing description (if listed) to mention overlay + ask.
- Consider a demo gif / asciinema recording for the README.
