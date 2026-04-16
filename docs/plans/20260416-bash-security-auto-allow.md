# Bash command security + auto-allow hardening

## Overview
- Harden Bash command matching by splitting compound commands and matching each segment independently, mirroring Claude Code's approach
- Auto-allow Agent and Skill tools as internal tools (explicit allow, not passthrough)
- Auto-allow read-only Bash commands (cat, head, tail, etc.) when path arguments are inside cwd or allowed dirs, using CC's safety regex pattern
- Add `$` anchoring to overlay-proposed Bash regexes
- Support additional allowed directories for path-based auto-allow (Read/Edit/Write/Grep/Glob/LS and readonly Bash commands)
- Release as v0.6.0

## Context (from discovery)
- CC splits compound commands via `splitCommand()` before matching. Each subcommand is checked independently. Deny on ANY subcommand takes priority over ask across all subcommands.
- CC uses `makeRegexForSafeCommand()` which creates `^<cmd>(?:\s|$)[^<>()$\x60|{}&;\n\r]*$` to auto-allow ~70 read-only commands. Additionally, CC validates that file path arguments are inside the working directory via `pathValidation.ts`.
- CC prevents prefix/wildcard rules from matching compound commands via explicit `isCompoundCommand` check.
- CC strips redirections (`>`, `>>`, `2>&1`) from subcommands so they don't pollute matching.
- passthru's `match_rule` currently matches the entire command string against regex. No splitting.
- `overlay-propose-rule.sh` proposes `^<first_word>\s` for Bash. No `$` anchor. Bare commands (e.g. `ls`) don't match.
- `permission_mode_auto_allows` only checks `$cwd`. CC also checks `additionalAllowedWorkingDirs`.
- Internal tool pass-through list emits `{"continue": true}` for Skill (triggers CC's native prompt). Agent is not handled at all (falls through to overlay).

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility

## Testing Strategy
- **unit tests**: required for every task (bats-core)
- run full suite with `bats tests/*.bats` after each task
- new test file `tests/command_splitting.bats` for compound command logic
- extend `tests/hook_handler.bats` for auto-allow changes
- extend `tests/overlay.bats` for anchoring changes

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with + prefix
- document issues/blockers with warning prefix
- update plan if implementation deviates from original scope

## Solution Overview

### Execution order for Bash commands
The following steps run in order for Bash tool calls. This clarifies how compound splitting, readonly auto-allow, deny, and allow/ask interact:

1. **Split**: compound command splitter runs first, producing segments
2. **Deny**: each segment is checked against deny rules. ANY segment match -> deny whole command
3. **Readonly auto-allow**: each segment is checked against the readonly command list + path validation (paths must be inside cwd or allowed dirs). ALL segments must pass for auto-allow
4. **Allow/Ask (document order)**: for each segment, find its first matching allow/ask rule. ALL segments must have a matching allow rule for the command to be allowed. If ANY segment's first match is ask, the whole command is ask. If ANY segment has no match, fall through to overlay

### Compound command splitting (mirrors CC)
Add `split_bash_command()` in perl (already a dependency for `pcre_match`). The splitter:
1. Tokenizes the command respecting single quotes, double quotes, `$()`, backticks, and escaped characters
2. Splits by unquoted `|`, `&&`, `||`, `;`, `&`
3. Strips redirections (`>`, `>>`, `<`, `2>&1`) from each segment (inside the perl tokenizer, one pass)
4. Returns NUL-separated segments for safe bash consumption

Matching semantics for Bash commands after splitting:
- **deny**: ANY segment matching a deny rule -> deny the whole command
- **allow**: ALL segments must match allow rules. Different segments may match different allow rules. If any segment has no matching allow rule, fall through to ask/overlay
- **ask**: ANY segment matching an ask rule (and no segment denied) -> ask

### Compound allow-matching algorithm
The current rule-iteration loop (iterate ordered rules, check match, first match wins) cannot express "all segments must be covered." For Bash compound commands, the algorithm is:

1. Collect the set of segments from the splitter
2. For each segment, walk the ordered allow/ask list independently and record the first matching entry (its list type: "allow" or "ask")
3. If ANY segment's first match is "ask", the whole command is "ask" (use that rule for audit)
4. If ALL segments' first matches are "allow", the whole command is "allow" (use the first segment's rule for audit)
5. If ANY segment has NO match at all, fall through to no-match path (overlay/native dialog)

This is a separate code path from the single-segment case.

### Read-only command auto-allow (mirrors CC)
Add a readonly command list mirroring CC's `READONLY_COMMANDS` + `makeRegexForSafeCommand` pattern. Each simple command becomes a PCRE: `^<cmd>(?:\s|$)[^<>()$\x60|{}&;\n\r]*$`. Commands with special requirements (echo, ls, find, cd, jq) use custom regexes.

**Path validation**: readonly auto-allow requires that all absolute path arguments in the command are inside cwd or an allowed dir. Relative paths are assumed to resolve inside cwd. This prevents `cat /etc/passwd` from being auto-allowed while allowing `cat src/main.rs` and `cat /Users/me/project/src/main.rs` (when cwd is `/Users/me/project`).

Path extraction: after matching the readonly regex, extract all non-flag tokens from the segment. For each token that starts with `/`, check it against cwd and allowed dirs using `_pm_path_inside_cwd`. Tokens not starting with `/` are treated as relative (allowed).

**Two-word commands** like `docker ps` use the full regex `^docker ps(?:\s|$)[^<>()$\x60|{}&;\n\r]*$`. The function iterates the full PCRE list against each segment, not a first-word hash lookup. This ensures `docker exec` does not match the `docker ps` regex.

Checked AFTER deny (deny always wins) and AFTER compound splitting (operates on segments). Checked BEFORE allow/ask document-order matching. This means deny rules can block read-only commands, but read-only commands don't need explicit allow rules.

### Auto-allow Agent + Skill
Add Agent and Skill to a new explicit-allow step early in the handler (before rule loading). Agent is not currently handled at all (falls through to overlay). Skill is currently in the internal tool passthrough list (emits `{"continue": true}`, which triggers CC's native "Use skill?" prompt). Both will emit `permissionDecision: "allow"` so CC never shows its own confirmation dialog. ToolSearch and the remaining CC-internal tools stay in the existing passthrough list.

### Overlay proposal anchoring
Change Bash proposals from `^<first_word>\s` to `^<first_word>(\s.*)?$`. This is fully anchored (both `^` and `$`) and handles bare commands (`ls`) and commands with args (`ls -la /tmp`).

Read/Edit/Write proposals use `^<parent>/` (intentionally a prefix for path matching, no `$`). WebFetch/WebSearch proposals use `^https?://<host>` (intentionally a prefix for URL matching, no `$`). No changes needed for these.

### Additional allowed directories
Add `allowed_dirs` support to passthru config (passthru.json schema). Bootstrap imports CC's `additionalAllowedWorkingDirs` from settings. The `permission_mode_auto_allows` function and the readonly auto-allow path check paths against `$cwd` AND each allowed dir.

**Schema**: new optional top-level key `allowed_dirs` in passthru.json (v2). Array of absolute path strings. Both authored and imported files may declare it.

**Merge semantics**: concatenate `allowed_dirs` from all four rule files (same order as allow/deny/ask), then deduplicate. This uses a separate `load_allowed_dirs` function (not modifying `load_rules` return value) to avoid changing the `{version, allow, deny, ask}` contract that `validate_rules`, `build_ordered_allow_ask`, and callers depend on. The function re-reads the same files but the IO cost is negligible (4 small JSON files, already in filesystem cache from `load_rules`).

## Technical Details

### Command splitter output format
Perl tokenizer runs inside the `split_bash_command` function. Outputs NUL-separated segments on stdout. Bash reads via `read -d ''`. Empty segments (from consecutive operators like `; ;`) are filtered. Parse failures return the original command as a single segment (fail-safe: no splitting means the full command is matched, which is the current behavior). Redirection stripping happens inside the perl tokenizer (one process, one pass).

The splitter always runs for Bash commands. No fast-path optimization for single commands. The perl process overhead is bounded by one spawn (same cost as `pcre_match`), and correctness is more important than micro-optimization. If the splitter returns exactly one segment, the command was simple.

### Read-only command list
Mirrored from CC source (`readOnlyValidation.ts` lines 1432-1503, 1509-1570):
- Simple commands (use generic safety regex): `cal`, `uptime`, `cat`, `head`, `tail`, `wc`, `stat`, `strings`, `hexdump`, `od`, `nl`, `id`, `uname`, `free`, `df`, `du`, `locale`, `groups`, `nproc`, `basename`, `dirname`, `realpath`, `cut`, `paste`, `tr`, `column`, `tac`, `rev`, `fold`, `expand`, `unexpand`, `fmt`, `comm`, `cmp`, `numfmt`, `readlink`, `diff`, `true`, `false`, `sleep`, `which`, `type`, `expr`, `test`, `getconf`, `seq`, `tsort`, `pr`, `docker ps`, `docker images`
- Custom regex commands: `echo` (safe subset, no `$`/backticks in double quotes), `pwd`, `whoami`, `ls` (no dangerous chars), `find` (no `-exec`/`-delete`), `cd` (no expansion), `jq` (no `-f`/`--from-file`/`--rawfile`/`--slurpfile`), `uniq` (flags only), `history` (bare or numeric), `alias`, `arch`, `node -v`, `node --version`, `python --version`, `python3 --version`
- Generic safety regex pattern for simple commands: `^<cmd>(?:\s|$)[^<>()$\x60|{}&;\n\r]*$`

### Path validation for readonly commands
After a segment matches a readonly regex, extract non-flag arguments:
1. Tokenize the segment by whitespace (respecting quotes)
2. Skip the command name (first token) and flag tokens (starting with `-`)
3. For each remaining token (potential file path):
   - If it starts with `/` (absolute path): check against cwd and allowed dirs via `_pm_path_inside_cwd`
   - If it does not start with `/` (relative path): treat as relative to cwd, allow
4. If ALL path arguments pass, the segment is auto-allowed. If ANY absolute path is outside cwd/allowed dirs, the segment fails readonly auto-allow (falls through to allow/ask matching)

### Allowed dirs config schema
New optional top-level key in passthru.json (v2):
```json
{
  "version": 2,
  "allowed_dirs": ["/path/to/extra/dir"],
  "allow": [...],
  "deny": [...],
  "ask": [...]
}
```
Both authored and imported passthru.json files may declare `allowed_dirs`. `load_allowed_dirs` concatenates arrays from all four files and deduplicates. Bootstrap reads `additionalAllowedWorkingDirs` from CC settings and writes to `allowed_dirs` in passthru.imported.json.

`validate_rules` is updated to tolerate (and validate) the new key: must be an array of non-empty strings, no path traversal (`/../`). `build_ordered_allow_ask` is unaffected (it only reads `allow` and `ask` keys).

## What Goes Where
- **Implementation Steps**: compound splitter, readonly auto-allow, Agent/Skill allow, overlay anchoring, allowed dirs, tests
- **Post-Completion**: release v0.6.0 via `/release-tools:new`

## Implementation Steps

### Task 1: Compound command splitter

**Files:**
- Modify: `hooks/common.sh` (add `split_bash_command` function)
- Create: `tests/command_splitting.bats`

- [ ] add `split_bash_command <command>` function to `hooks/common.sh` using inline perl
- [ ] implement quote-aware splitting by `|`, `&&`, `||`, `;`, `&` (respect single/double quotes, `$()`, backticks, backslash escaping)
- [ ] strip redirections (`>`, `>>`, `<`, `2>&1`, `2>/dev/null`) from each segment inside the perl tokenizer
- [ ] output NUL-separated segments, filter empty segments
- [ ] fail-safe: parse errors return original command as single segment
- [ ] write tests for single commands (no split needed, returns 1 segment)
- [ ] write tests for pipe splitting: `ls | head` -> `["ls", "head"]`
- [ ] write tests for `&&` and `||` splitting
- [ ] write tests for `;` and `&` splitting
- [ ] write tests for quoted strings preserved: `echo 'foo && bar'` -> single segment
- [ ] write tests for double-quoted strings preserved: `echo "foo | bar"` -> single segment
- [ ] write tests for `$()` subshell preserved: `echo $(foo | bar)` -> single segment
- [ ] write tests for nested subshell: `echo $(cat $(find . -name "*.txt"))` -> single segment
- [ ] write tests for backtick subshell preserved: `` echo `foo | bar` `` -> single segment
- [ ] write tests for redirection stripping: `ls > /tmp/out` -> `["ls"]`
- [ ] write tests for stderr redirect stripping: `cmd 2>&1` -> `["cmd"]`
- [ ] write tests for mixed: `curl url | head && echo done` -> `["curl url", "head", "echo done"]`
- [ ] write test for parse failure fallback (malformed quoting returns original as single segment)
- [ ] run tests - must pass before next task

### Task 2: Integrate splitter into pre-tool-use matching

**Files:**
- Modify: `hooks/handlers/pre-tool-use.sh` (split Bash commands before matching)
- Modify: `hooks/common.sh` (add `match_all_segments` helper)
- Modify: `tests/hook_handler.bats` (add compound command test cases)

- [ ] add `match_all_segments <segments_array> <ordered_rules>` helper that implements the per-segment-first-match algorithm described in Solution Overview
- [ ] in step 5 (deny matching): for Bash tool, split command into segments via `split_bash_command`, check each segment against deny rules. ANY segment matching deny -> deny whole command
- [ ] in step 6 (allow/ask matching): for Bash tool with multiple segments, use `match_all_segments` instead of the current single-match loop. For single-segment commands, use the existing loop (no behavior change)
- [ ] write tests: deny rule on second segment blocks compound command (`echo hello && rm -rf /` with deny on `^rm`)
- [ ] write tests: allow rule on first segment only does NOT allow compound command
- [ ] write tests: allow rules covering ALL segments allows compound command (two different rules covering two segments)
- [ ] write tests: ask rule on any segment triggers ask for compound
- [ ] write tests: one segment matches allow, another has no match -> falls through to overlay
- [ ] write tests: single command (no operators) works identically to current behavior
- [ ] run full test suite - must pass before next task

### Task 3: Read-only Bash command auto-allow

**Files:**
- Modify: `hooks/common.sh` (add `is_readonly_command` function + command list + path validation)
- Modify: `hooks/handlers/pre-tool-use.sh` (add readonly check after deny, before allow/ask)
- Modify: `tests/hook_handler.bats` (add readonly auto-allow tests)

- [ ] add `PASSTHRU_READONLY_COMMANDS` array in `hooks/common.sh` mirroring CC's simple command list
- [ ] add `PASSTHRU_READONLY_REGEXES` array for commands needing custom patterns (echo, pwd, ls, find, cd, jq, etc.)
- [ ] add `is_readonly_command <segment>` function: iterates full PCRE list against the segment (not first-word lookup). Returns 0 if readonly, 1 otherwise
- [ ] add `readonly_paths_allowed <segment> <cwd> <allowed_dirs_json>` function: extracts non-flag tokens, checks absolute paths against cwd + allowed dirs. Returns 0 if all paths allowed, 1 if any outside
- [ ] for compound commands: split first (Task 1), then check ALL segments. All must be readonly AND have valid paths
- [ ] insert readonly check in pre-tool-use.sh after deny (step 5) and before allow/ask (step 6). Operates on segments, not raw command
- [ ] emit explicit allow with reason "passthru readonly: <cmd>" and audit source "passthru-readonly"
- [ ] write tests: `cat src/main.rs` auto-allowed (relative path, inside cwd)
- [ ] write tests: `cat /Users/me/project/src/main.rs` auto-allowed when cwd is `/Users/me/project`
- [ ] write tests: `cat /etc/passwd` NOT auto-allowed (absolute path outside cwd)
- [ ] write tests: `head -n 10 file.txt` auto-allowed (relative path)
- [ ] write tests: `ls /Users/me/project/docs/` auto-allowed when cwd is `/Users/me/project`
- [ ] write tests: `ls /tmp/random` NOT auto-allowed (outside cwd)
- [ ] write tests: `cat file.txt | head` auto-allowed (both segments readonly, relative paths)
- [ ] write tests: `cat file.txt | rm -rf /` NOT auto-allowed (rm is not readonly)
- [ ] write tests: deny rule overrides readonly auto-allow
- [ ] write tests: `echo "safe string"` auto-allowed, `echo $(dangerous)` not auto-allowed
- [ ] write tests: `docker ps` matches `docker ps` regex, `docker exec` does NOT
- [ ] write tests: readonly + allowed_dirs integration (path in allowed dir is auto-allowed)
- [ ] run full test suite - must pass before next task

### Task 4: Auto-allow Agent and Skill tools

**Files:**
- Modify: `hooks/handlers/pre-tool-use.sh` (add Agent/Skill to explicit allow, remove Skill from passthrough list)
- Modify: `tests/hook_handler.bats` (add Agent/Skill auto-allow tests)

- [ ] add new step between current step 3 (plugin self-allow) and step 4 (load rules): internal tool explicit allow
- [ ] emit `permissionDecision: "allow"` with reason "passthru internal: <tool>" for Agent and Skill
- [ ] remove Skill from existing step 7 internal tool passthrough list (it moves to the new explicit allow step)
- [ ] keep ToolSearch, TaskCreate, AskUserQuestion, and all other CC-internal tools in step 7 passthrough list
- [ ] audit Agent and Skill as source "passthru-internal"
- [ ] write tests: Agent tool call returns explicit allow decision (not passthrough)
- [ ] write tests: Skill tool call returns explicit allow decision (not passthrough)
- [ ] write tests: ToolSearch still returns passthrough (not allow)
- [ ] write tests: TaskCreate still returns passthrough (not allow)
- [ ] run full test suite - must pass before next task

### Task 5: Anchor overlay-proposed Bash regexes

**Files:**
- Modify: `scripts/overlay-propose-rule.sh` (fix Bash category anchoring)
- Modify: `tests/overlay.bats` (update/add overlay proposal tests)

- [ ] change Bash category from `^<first_word>\s` to `^<first_word>(\s.*)?$`
- [ ] this matches bare commands (`ls`), commands with args (`ls -la`), and is fully anchored
- [ ] Read/Edit/Write proposals: intentionally left as prefix (`^<parent>/`), no change needed
- [ ] WebFetch/WebSearch proposals: intentionally left as prefix (`^https?://<host>`), no change needed
- [ ] write tests: proposed rule for `ls` matches `ls` and `ls -la` but not `ls && evil`
- [ ] write tests: proposed rule for `git status` matches bare invocation
- [ ] write tests: proposed rule for bare command (no args) matches exact command
- [ ] run full test suite - must pass before next task

### Task 6: Additional allowed directories

**Files:**
- Modify: `hooks/common.sh` (add `load_allowed_dirs` function, update `permission_mode_auto_allows` signature)
- Modify: `hooks/handlers/pre-tool-use.sh` (load allowed dirs, pass to auto-allow and readonly checks)
- Modify: `scripts/bootstrap.sh` (import `additionalAllowedWorkingDirs` from CC settings)
- Modify: `scripts/verify.sh` (validate `allowed_dirs` field)
- Modify: `docs/rule-format.md` (document `allowed_dirs` field)
- Modify: `tests/hook_handler.bats` (add allowed dirs tests)
- Modify: `tests/bootstrap.bats` (add import tests)
- Modify: `tests/verifier.bats` (add allowed_dirs validation tests)

- [ ] add `load_allowed_dirs` function to `hooks/common.sh`: reads `allowed_dirs` from all four rule files, concatenates, deduplicates. Returns JSON array on stdout. Separate from `load_rules` to preserve `{version, allow, deny, ask}` contract
- [ ] add `_pm_path_inside_any_allowed <path> <cwd> <allowed_dirs_json>` helper: checks path against cwd first, then each allowed dir. Returns 0 if inside any
- [ ] update `permission_mode_auto_allows` to accept allowed dirs JSON as 5th parameter
- [ ] update pre-tool-use.sh: call `load_allowed_dirs` once, pass result to `permission_mode_auto_allows` and readonly path validation
- [ ] add bootstrap support: read `additionalAllowedWorkingDirs` from CC settings files (user + project), write to `allowed_dirs` in passthru.imported.json
- [ ] update `validate_rules` to tolerate and validate `allowed_dirs` key: must be array of non-empty strings, reject path traversal (`/../`)
- [ ] update docs/rule-format.md with `allowed_dirs` documentation
- [ ] update CONTRIBUTING.md with guidance on `allowed_dirs` usage
- [ ] write tests: Read tool auto-allowed for file in additional allowed dir
- [ ] write tests: Write tool auto-allowed in acceptEdits mode for file in additional allowed dir
- [ ] write tests: Grep tool auto-allowed for path in additional allowed dir
- [ ] write tests: file outside all allowed dirs falls through to overlay
- [ ] write tests: bootstrap imports additionalAllowedWorkingDirs from settings
- [ ] write tests: verify.sh validates allowed_dirs field (valid array, rejects traversal)
- [ ] write tests: verify.sh accepts passthru.json without allowed_dirs (backward compatible)
- [ ] write tests: readonly auto-allow uses allowed dirs for path validation
- [ ] run full test suite - must pass before next task

### Task 7: Verify acceptance criteria

- [ ] run full test suite: `bats tests/*.bats` - all pass
- [ ] spot-check: compound command deny on any segment
- [ ] spot-check: compound command allow requires all segments
- [ ] spot-check: readonly `cat src/file` auto-allowed, `cat /etc/passwd` not
- [ ] spot-check: Agent and Skill get explicit allow
- [ ] spot-check: overlay proposals anchored with `$`
- [ ] spot-check: additional allowed dirs work for path-based tools and readonly Bash

### Task 8: [Final] Update documentation and release

- [ ] update CLAUDE.md with new patterns (readonly auto-allow, compound splitting, allowed dirs)
- [ ] update README.md with new features
- [ ] update CONTRIBUTING.md with guidance on extending readonly command list and compound splitter
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Release:**
- Run `/release-tools:new` to create v0.6.0 release
- Bump `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` to `0.6.0`
- Tag `v0.6.0` and publish GitHub release

**Manual verification:**
- Test overlay dialog with Bash compound command (should prompt for unmatched segments)
- Test Agent tool call in live session (should not show CC native prompt)
- Test Skill invocation (should not show "Use skill?" prompt)
- Test `cat src/file.txt` (should auto-allow without overlay)
- Test `cat /etc/passwd` (should NOT auto-allow, should hit overlay)
- Test `ls /path/inside/cwd/` (should auto-allow)
